import ConcurrencyExtras
public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

#if canImport(UIKit)
  import UIKit
#endif

// Product analytics (`stitchdb.analytics`): the events your app tracks, linked to the signed-in user (an anonymous id
// before sign-in, merged into the user when they sign in), for active users, funnels, retention and breakdowns in
// Studio › Analytics.
//
// Nothing is sent before `start()`; events tracked before it wait in memory (at most 100). After start the queue is
// written to disk on every change (at most 1000 events, the oldest are dropped), so events tracked offline survive an
// app kill and are sent on the next start.
// Local layout (one directory per project): `anon` the anonymous id of this install, `optout` present while the user
// opted out, `queue.json` the events not sent yet.

/// One tracked event as it is sent to `/analytics/v1/track`. Change it in `beforeSend`.
public struct AnalyticsEvent: Codable, Sendable, Equatable {
  public var name: String
  public var props: JSONObject
  /// ISO 8601 time.
  public var at: String

  public init(name: String, props: JSONObject = [:], at: String? = nil) {
    self.name = name
    self.props = props
    self.at = at ?? crashIsoNow()
  }
}

/// Product analytics. Use the one on ``StitchClient/analytics``.
///
/// ```swift
/// stitchdb.analytics.start(release: "1.4.0")
/// stitchdb.analytics.track("purchase", props: ["plan": "pro", "amount": 29])
/// await stitchdb.analytics.optOut()   // the user does not want to be tracked
/// ```
///
/// Nothing is sent until you call ``start(release:beforeSend:flushInterval:)`` and the project has analytics turned on
/// (Studio › Analytics). Events are sent in batches in the background (every `flushInterval`, when 20 are waiting,
/// when the user signs in or out and when the app goes to the background). Passwords, tokens, keys and e-mail
/// addresses are removed by StitchDB before anything is stored.
public final class AnalyticsClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch
  public typealias BeforeSend = @Sendable (AnalyticsEvent) -> AnalyticsEvent?
  /// Calls the handler when the signed-in user changes; returns a function that stops listening.
  typealias AuthChanges = @Sendable (_ handler: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

  static let maxQueue = 1000
  static let maxEarly = 100
  static let batchSize = 100
  static let flushAt = 20
  static let maxPropsBytes = 8 * 1024

  struct State {
    var started = false
    var disabled = false
    var optedOut = false
    var release: String?
    var beforeSend: BeforeSend?
    var directory: URL
    var anonID = ""
    let sessionID = UUID().uuidString.lowercased()
    var queue: [AnalyticsEvent] = []
    var sending: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var stopListening: [@Sendable () -> Void] = []
  }

  private let url: URL
  private let headers: [String: String]
  private let logger: (any StitchLogger)?
  private let authChanges: AuthChanges?
  private let fetch = LockIsolated<Fetch?>(nil)
  private let state: LockIsolated<State>

  init(
    url: URL, headers: [String: String], directory: URL, logger: (any StitchLogger)? = nil,
    authChanges: AuthChanges? = nil, fetch: Fetch? = nil
  ) {
    self.url = url
    self.headers = headers
    self.logger = logger
    self.authChanges = authChanges
    var initial = State(directory: directory)
    initial.anonID = Self.loadAnonID(in: directory)
    initial.optedOut = FileManager.default.fileExists(atPath: directory.appendingPathComponent("optout").path)
    let ready = initial
    self.state = LockIsolated(ready)
    self.fetch.setValue(fetch)
  }

  /// Application Support (Caches on tvOS) on Apple platforms, the temporary directory elsewhere; one folder per project.
  public static func defaultDirectory(namespace: String) -> URL {
    stitchDataDirectory("analytics", namespace: namespace)
  }

  func setFetch(_ fetch: @escaping Fetch) { self.fetch.setValue(fetch) }

  // MARK: Start / stop

  /// Starts sending: the events tracked so far and the ones kept from earlier runs go out in the background. Calling it
  /// again updates the options.
  ///
  /// - Parameters:
  ///   - release: Your app's version, for the breakdown by release.
  ///   - beforeSend: Change an event or return nil to drop it.
  ///   - flushInterval: Send every this many seconds (default 10, at least 1), or when 20 events are waiting.
  public func start(release: String? = nil, beforeSend: BeforeSend? = nil, flushInterval: TimeInterval = 10) {
    let first = state.withValue { s -> Bool in
      s.release = release
      s.beforeSend = beforeSend
      if s.started { return false }
      s.started = true
      s.disabled = false
      s.queue = Array((Self.loadQueue(in: s.directory) + s.queue).suffix(Self.maxQueue))
      if !s.optedOut { Self.saveQueue(s.queue, in: s.directory) }
      return true
    }
    guard first else { return }

    let interval = UInt64(max(flushInterval, 1) * 1_000_000_000)
    let timer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        guard let self, !Task.isCancelled else { return }
        await self.flush()
      }
    }
    var off: [@Sendable () -> Void] = [{ timer.cancel() }]
    // a batch belongs to one user: send what is waiting when the user changes
    if let authChanges {
      off.append(authChanges { [weak self] in
        guard let self else { return }
        Task { await self.flush() }
      })
    }
    #if canImport(UIKit) && !os(watchOS)
      let observer = UncheckedSendable(
        NotificationCenter.default.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
          guard let self else { return }
          Task { await self.flush() }
        }
      )
      off.append { NotificationCenter.default.removeObserver(observer.value) }
    #endif
    let listeners = off
    state.withValue { s in
      s.timer = timer
      s.stopListening = listeners
    }
    kick()
  }

  /// Stops sending (for example when the user withdraws consent). Waiting events stay on the device and are sent after
  /// the next ``start(release:beforeSend:flushInterval:)``.
  public func stop() {
    let off = state.withValue { s -> [@Sendable () -> Void] in
      s.started = false
      s.timer = nil
      if !s.optedOut { Self.saveQueue(s.queue, in: s.directory) }
      defer { s.stopListening = [] }
      return s.stopListening
    }
    for f in off { f() }
  }

  /// Whether ``start(release:beforeSend:flushInterval:)`` was called (and not ``stop()``).
  public var isStarted: Bool { state.value.started }

  // MARK: Track

  /// Tracks an event with properties (flat values are easiest to break down by). Names are letters, digits, `_ $ . : -
  /// /` and spaces, up to 64 characters; other names are dropped.
  public func track(_ name: String, props: JSONObject = [:]) {
    let (skip, beforeSend) = state.withValue { s in (s.optedOut || s.disabled, s.beforeSend) }
    if skip { return }
    guard Self.isValidName(name) else {
      logger?.debug(
        "stitchdb analytics: \"\(name)\" is not a valid event name (letters, digits, _ $ . : - / and spaces, up to 64)"
      )
      return
    }
    let built = AnalyticsEvent(name: name, props: props)
    let event: AnalyticsEvent? = if let beforeSend { beforeSend(built) } else { built }
    guard let event else { return }
    if let data = try? JSONEncoder().encode(event.props), data.count > Self.maxPropsBytes {
      logger?.debug("stitchdb analytics: the props of \"\(event.name)\" are over 8 KB, the event is dropped")
      return
    }
    let full = state.withValue { s -> Bool in
      guard !s.optedOut, !s.disabled else { return false }
      s.queue.append(event)
      let max = s.started ? Self.maxQueue : Self.maxEarly
      if s.queue.count > max { s.queue.removeFirst(s.queue.count - max) }
      guard s.started else { return false }
      Self.saveQueue(s.queue, in: s.directory)
      return s.queue.count >= Self.flushAt
    }
    if full { kick() }
  }

  /// Sends what is waiting now.
  public func flush() async {
    await kick()?.value
  }

  // MARK: Opt-out

  /// The user does not want to be tracked: their events are deleted on the server and no new ones are tracked or sent
  /// (remembered on this device).
  public func optOut() async {
    state.withValue { s in
      s.optedOut = true
      s.queue = []
      Self.saveQueue([], in: s.directory)
      try? FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
      try? Data("1".utf8).write(to: s.directory.appendingPathComponent("optout"), options: .atomic)
    }
    _ = try? await sendJSON(fetch.value, url.appendingPathComponent("opt-out"), headers: headers, body: JSONObject())
  }

  /// Tracks again after ``optOut()``.
  public func optIn() async {
    state.withValue { s in
      s.optedOut = false
      try? FileManager.default.removeItem(at: s.directory.appendingPathComponent("optout"))
    }
    _ = try? await sendJSON(
      fetch.value, url.appendingPathComponent("opt-out"), method: "DELETE", headers: headers, body: AnyJSON?.none
    )
  }

  /// Whether the user opted out on this device.
  public var isOptedOut: Bool { state.value.optedOut }

  /// The id of this install before sign-in (kept on the device).
  public var anonymousId: String { state.value.anonID }

  // MARK: Queue

  var queuedEvents: [AnalyticsEvent] { state.value.queue }

  /// `^[$A-Za-z0-9_][\w$.:\- /]{0,63}$`, the rule of the server (which refuses the whole batch otherwise).
  static func isValidName(_ name: String) -> Bool {
    let chars = Array(name.unicodeScalars)
    guard let first = chars.first, chars.count <= 64 else { return false }
    func word(_ c: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_"
    }
    guard word(first) || first == "$" else { return false }
    return chars.dropFirst().allSatisfy { word($0) || "$.:- /".unicodeScalars.contains($0) }
  }

  /// Starts sending the queue unless a send is already running; returns the running send.
  @discardableResult
  private func kick() -> Task<Void, Never>? {
    state.withValue { s in
      if let sending = s.sending { return sending }
      guard s.started, !s.disabled, !s.optedOut, !s.queue.isEmpty else { return nil }
      let task = Task { await self.sendQueue() }
      s.sending = task
      return task
    }
  }

  private func sendQueue() async {
    while true {
      let next: (batch: [AnalyticsEvent], body: AnyJSON)? = state.withValue { s in
        let batch = s.started && !s.disabled && !s.optedOut ? Array(s.queue.prefix(Self.batchSize)) : []
        if batch.isEmpty {
          s.sending = nil
          return nil
        }
        var body: JSONObject = [
          "anon_id": .string(s.anonID), "session_id": .string(s.sessionID),
          "release": s.release.map(AnyJSON.string) ?? .null, "platform": .string(crashPlatform),
          "os": .string(Self.osDescription),
          "events": .array(
            batch.map { e -> AnyJSON in .object(["name": .string(e.name), "props": .object(e.props), "at": .string(e.at)]) }
          ),
        ]
        if let country = Self.country { body["country"] = .string(country) }
        return (batch, .object(body))
      }
      guard let next else { return }
      let status: Int
      do {
        status = try await sendJSON(fetch.value, url.appendingPathComponent("track"), headers: headers, body: next.body)
      } catch {
        status = 0
      }
      let keepGoing = state.withValue { s -> Bool in
        switch status {
        case 403, 404:  // analytics is off for the project: stop for this run
          s.disabled = true
          s.queue = []
        case 200..<300, 400, 413:  // sent, or refused for good
          for event in next.batch {
            if let i = s.queue.firstIndex(of: event) { s.queue.remove(at: i) }
          }
        default:  // offline, busy or the month's events are used up (429): kept on disk for later
          if !s.optedOut { Self.saveQueue(s.queue, in: s.directory) }
          s.sending = nil
          return false
        }
        if !s.optedOut { Self.saveQueue(s.queue, in: s.directory) }
        return true
      }
      if !keepGoing { return }
    }
  }

  // MARK: Device

  /// `iOS 17.2`, `Linux 6.8.0`.
  static let osDescription: String = {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(osName) \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
  }()

  /// The 2-letter region of the device locale (`DE`), if it has one.
  static var country: String? {
    guard let region = Locale.current.region?.identifier, region.count == 2,
      region.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("a"..."z").contains($0) })
    else { return nil }
    return region.uppercased()
  }

  // MARK: Disk

  private static func loadAnonID(in directory: URL) -> String {
    let file = directory.appendingPathComponent("anon")
    if let id = try? String(contentsOf: file, encoding: .utf8), !id.isEmpty { return id }
    let id = UUID().uuidString.lowercased()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(id.utf8).write(to: file, options: .atomic)
    return id
  }

  static func loadQueue(in directory: URL) -> [AnalyticsEvent] {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("queue.json")) else { return [] }
    return (try? JSONDecoder().decode([AnalyticsEvent].self, from: data)) ?? []
  }

  private static func saveQueue(_ queue: [AnalyticsEvent], in directory: URL) {
    let file = directory.appendingPathComponent("queue.json")
    if queue.isEmpty {
      try? FileManager.default.removeItem(at: file)
      return
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? JSONEncoder().encode(queue).write(to: file, options: .atomic)
  }
}

// MARK: - StitchClient

extension StitchClient {
  /// The default directory for ``analytics``: one folder per project (see ``AnalyticsClient/defaultDirectory(namespace:)``).
  static func analyticsDirectory(for url: URL) -> URL {
    AnalyticsClient.defaultDirectory(namespace: stitchNamespace(for: url))
  }
}

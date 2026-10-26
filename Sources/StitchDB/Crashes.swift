import ConcurrencyExtras
public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

#if canImport(Darwin)
  import Darwin
#endif

// Crash and error reporting (`stitchdb.crashes`): uncaught Objective-C exceptions on Apple platforms and errors you
// report yourself, grouped into issues in Studio › Crashes with the stack, app version, device, the signed-in user and
// the user's last actions and API calls ("crashed right after GET /rest/v1/orders returned 500").
//
// Nothing is captured, recorded or sent before `start()`. Reports are kept on disk until the server has them
// (`<directory>/queue.json`, at most 30), so a report written while the app is dying is sent on the next start.
// Local layout (one directory per project): `install` the id of this app install, `queue.json` the reports not
// sent yet, `session` the day and release the last daily session was sent for.

// MARK: - Types

/// Something the user did or the app went through; the last ones are sent with every report.
public struct Breadcrumb: Codable, Sendable, Equatable {
  public enum Level: String, Codable, Sendable {
    case debug, info, warning, error
  }

  /// `api`, `navigation`, `ui`, `log` or your own word.
  public var type: String
  public var message: String?
  public var level: Level
  public var data: JSONObject?
  /// ISO 8601 time.
  public var at: String

  public init(type: String = "log", message: String? = nil, level: Level = .info, data: JSONObject? = nil, at: String? = nil) {
    self.type = type
    self.message = message
    self.level = level
    self.data = data
    self.at = at ?? crashIsoNow()
  }
}

/// One crash or error as it is sent to `/crashes/v1/report`. Change it in `beforeSend`.
public struct CrashReport: Codable, Sendable, Equatable {
  public struct Exception: Codable, Sendable, Equatable {
    public var type: String
    public var message: String
    public var stack: String?
    public var mechanism: String?

    public init(type: String, message: String, stack: String? = nil, mechanism: String? = nil) {
      self.type = type
      self.message = message
      self.stack = stack
      self.mechanism = mechanism
    }
  }

  /// `ios` on iOS, `swift` elsewhere.
  public var platform: String
  public var release: String?
  public var environment: String
  public var installID: String
  /// ISO 8601 time of the crash.
  public var at: String
  public var handled: Bool
  public var exception: Exception
  public var breadcrumbs: [Breadcrumb]
  public var device: JSONObject
  public var context: JSONObject
  public var fingerprint: [String]?

  enum CodingKeys: String, CodingKey {
    case platform, release, environment, at, handled, exception, breadcrumbs, device, context, fingerprint
    case installID = "install_id"
  }
}

// MARK: - Helpers

func crashIsoNow() -> String {
  Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
}

/// `ios` on iOS, `swift` elsewhere (crash reports and analytics).
let crashPlatform: String = {
  #if os(iOS)
    return "ios"
  #else
    return "swift"
  #endif
}()

let osName: String = {
  #if os(macOS)
    return "macOS"
  #elseif os(visionOS)
    return "visionOS"
  #elseif os(iOS)
    #if targetEnvironment(macCatalyst)
      return "macCatalyst"
    #else
      return "iOS"
    #endif
  #elseif os(watchOS)
    return "watchOS"
  #elseif os(tvOS)
    return "tvOS"
  #elseif os(Android)
    return "Android"
  #elseif os(Linux)
    return "Linux"
  #elseif os(Windows)
    return "Windows"
  #else
    return "unknown"
  #endif
}()

#if canImport(Darwin)
  private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
  }
#endif

private let deviceModel: String? = {
  #if canImport(Darwin)
    if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulator }
    #if os(macOS) || targetEnvironment(macCatalyst)
      return sysctlString("hw.model")
    #else
      return sysctlString("hw.machine")
    #endif
  #else
    return nil
  #endif
}()

private let deviceArch: String = {
  #if arch(arm64)
    return "arm64"
  #elseif arch(x86_64)
    return "x86_64"
  #elseif arch(arm)
    return "arm"
  #elseif arch(i386)
    return "i386"
  #else
    return "unknown"
  #endif
}()

private func deviceInfo() -> JSONObject {
  let v = ProcessInfo.processInfo.operatingSystemVersion
  var d: JSONObject = [
    "os": .string(osName),
    "os_version": .string("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"),
    "arch": .string(deviceArch),
    "locale": .string(Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
    "runtime": "swift",
    "sdk": .string("stitchdb-swift/\(version)"),
  ]
  if let deviceModel { d["model"] = .string(deviceModel) }
  return d
}

/// Application Support (Caches on tvOS) on Apple platforms, the temporary directory elsewhere:
/// `stitchdb-<kind>-<namespace>`, one folder per project.
func stitchDataDirectory(_ kind: String, namespace: String) -> URL {
  let fm = FileManager.default
  #if os(tvOS)
    let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
  #elseif canImport(Darwin)
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
  #else
    let base = fm.temporaryDirectory
  #endif
  return base.appendingPathComponent("stitchdb-\(kind)-\(namespace)", isDirectory: true)
}

/// The project namespace of a client URL: the first label of the host.
func stitchNamespace(for url: URL) -> String {
  let host = url.host(percentEncoded: false) ?? "default"
  return String(host.split(separator: ".").first ?? "default")
}

/// Sends a JSON request with `fetch` (which adds the access token) and returns the status code (0 without one).
func sendJSON(
  _ fetch: CrashesClient.Fetch?, _ url: URL, method: String = "POST", headers: [String: String],
  body: (some Encodable)?
) async throws -> Int {
  guard let fetch else { throw URLError(.cancelled) }
  var request = URLRequest(url: url)
  for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
  request.httpMethod = method
  if let body {
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
  }
  let (_, response) = try await fetch(request)
  return (response as? HTTPURLResponse)?.statusCode ?? 0
}

private func currentStack(dropping n: Int) -> String {
  Thread.callStackSymbols.dropFirst(n).joined(separator: "\n")
}

/// `path?key1&key2` of a request URL: no host, no query values.
private func breadcrumbURL(_ url: URL) -> String {
  guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
  let path = c.percentEncodedPath
  let keys = (c.queryItems ?? []).map(\.name)
  return keys.isEmpty ? path : path + "?" + keys.joined(separator: "&")
}

private func errorCode(in data: Data) -> String? {
  guard let o = (try? JSONDecoder().decode(AnyJSON.self, from: data))?.objectValue else { return nil }
  for key in ["code", "error_code", "error"] {
    switch o[key] {
    case .string(let s)?: return s
    case .integer(let i)?: return String(i)
    default: continue
    }
  }
  return nil
}

// MARK: - Client

/// Crash and error reporting. Use the one on ``StitchClient/crashes``.
///
/// ```swift
/// stitchdb.crashes.start(release: "1.4.0")
/// do { try await checkout() } catch { stitchdb.crashes.captureError(error, context: ["step": "payment"]) }
/// stitchdb.crashes.addBreadcrumb(type: "ui", message: "tapped Checkout")
/// ```
///
/// Nothing is sent until you call ``start(release:environment:captureUnhandled:maxBreadcrumbs:directory:beforeSend:)``
/// and the project has crash reporting turned on (Studio › Crashes). Ask for consent first where you need it, or decide
/// per report in `beforeSend`. Passwords, tokens, keys and e-mail addresses are removed by StitchDB before anything is
/// stored.
public final class CrashesClient: Sendable {
  public typealias Fetch = @Sendable (_ request: URLRequest) async throws -> (Data, URLResponse)
  public typealias BeforeSend = @Sendable (CrashReport) -> CrashReport?

  static let maxQueue = 30
  static let batchSize = 20

  struct State {
    var started = false
    var disabled = false
    var release: String?
    var environment = "production"
    var maxBreadcrumbs = 50
    var beforeSend: BeforeSend?
    var directory: URL
    var installID = ""
    var crumbs: [Breadcrumb] = []
    var queue: [CrashReport] = []
    var sending: Task<Void, Never>?
    var starting: Task<Void, Never>?
    var hooked = false
  }

  private let url: URL
  private let headers: [String: String]
  private let fetch = LockIsolated<Fetch?>(nil)
  private let state: LockIsolated<State>

  /// - Parameters:
  ///   - url: The crash reporting API, `<project URL>/crashes/v1`.
  ///   - headers: Headers for every request (`apikey`, …).
  ///   - directory: Where reports wait to be sent (default: see ``defaultDirectory(namespace:)``).
  ///   - fetch: Performs a request (adds the current access token).
  public init(url: URL, headers: [String: String], directory: URL, fetch: Fetch? = nil) {
    self.url = url
    self.headers = headers
    self.state = LockIsolated(State(directory: directory))
    self.fetch.setValue(fetch)
  }

  /// Application Support (Caches on tvOS) on Apple platforms, the temporary directory elsewhere; one folder per project.
  public static func defaultDirectory(namespace: String) -> URL {
    stitchDataDirectory("crashes", namespace: namespace)
  }

  func setFetch(_ fetch: @escaping Fetch) { self.fetch.setValue(fetch) }

  // MARK: Start / stop

  /// Starts reporting: catches uncaught exceptions (unless `captureUnhandled` is false), sends the reports kept from
  /// earlier runs and the daily session (for crash-free users). Calling it again updates the options.
  ///
  /// - Parameters:
  ///   - release: Your app's version, e.g. `"1.4.0"` or a build number: issues and crash-free users are per release.
  ///   - environment: Default `"production"`.
  ///   - captureUnhandled: Report uncaught Objective-C exceptions (`NSException`, Apple platforms). Default true.
  ///   - maxBreadcrumbs: Breadcrumbs kept (default 50, at most 100).
  ///   - directory: Where reports wait to be sent (default: one folder per project in Application Support).
  ///   - beforeSend: Change a report or return nil to not send it (consent, filtering).
  public func start(
    release: String? = nil,
    environment: String = "production",
    captureUnhandled: Bool = true,
    maxBreadcrumbs: Int = 50,
    directory: URL? = nil,
    beforeSend: BeforeSend? = nil
  ) {
    let first = state.withValue { s -> Bool in
      s.release = release
      s.environment = environment
      s.maxBreadcrumbs = min(max(maxBreadcrumbs, 0), 100)
      s.beforeSend = beforeSend
      if s.started { return false }
      if let directory { s.directory = directory }
      s.started = true
      s.disabled = false
      s.installID = Self.loadInstallID(in: s.directory)
      s.queue = Array(Self.loadQueue(in: s.directory).suffix(Self.maxQueue))
      return true
    }
    guard first else { return }
    if captureUnhandled { UncaughtExceptions.add(self) }
    let task = Task { [self] in
      await sendSession()
      await kick()?.value
    }
    state.withValue { $0.starting = task }
  }

  /// Stops reporting and removes the exception handler (for example when the user withdraws consent).
  public func stop() {
    let hooked = state.withValue { s -> Bool in
      s.started = false
      return s.hooked
    }
    if hooked { UncaughtExceptions.remove(self) }
  }

  /// Whether ``start(release:environment:captureUnhandled:maxBreadcrumbs:directory:beforeSend:)`` was called (and not
  /// ``stop()``).
  public var isStarted: Bool { state.value.started }

  // MARK: Capture

  /// Reports an error you caught. Returns once it is queued on disk; sending happens in the background (or `await
  /// flush()`).
  public func captureError(
    _ error: any Error,
    context: JSONObject? = nil,
    fingerprint: [String]? = nil,
    handled: Bool = true
  ) {
    capture(error, context: context, fingerprint: fingerprint, handled: handled)
  }

  /// The same as ``captureError(_:context:fingerprint:handled:)`` (the name the other StitchDB SDKs use).
  public func captureException(
    _ error: any Error,
    context: JSONObject? = nil,
    fingerprint: [String]? = nil,
    handled: Bool = true
  ) {
    capture(error, context: context, fingerprint: fingerprint, handled: handled)
  }

  private func capture(_ error: any Error, context: JSONObject?, fingerprint: [String]?, handled: Bool) {
    guard isStarted else { return }
    var message = String(describing: error)
    if message.isEmpty { message = error.localizedDescription }
    enqueue(
      CrashReport.Exception(
        type: String(reflecting: type(of: error)), message: message, stack: currentStack(dropping: 2)
      ),
      handled: handled, context: context, fingerprint: fingerprint
    )
  }

  /// Reports a message as an error, e.g. a state that should never happen.
  public func captureMessage(_ message: String, context: JSONObject? = nil, fingerprint: [String]? = nil) {
    guard isStarted else { return }
    enqueue(
      CrashReport.Exception(type: "Message", message: message, stack: currentStack(dropping: 1)),
      handled: true, context: context, fingerprint: fingerprint
    )
  }

  /// Something the user did or the app went through; the last ones are sent with the next report.
  public func addBreadcrumb(
    type: String = "log",
    message: String? = nil,
    data: JSONObject? = nil,
    level: Breadcrumb.Level = .info
  ) {
    addBreadcrumb(Breadcrumb(type: type, message: message, level: level, data: data))
  }

  /// Adds a breadcrumb you built yourself.
  public func addBreadcrumb(_ crumb: Breadcrumb) {
    state.withValue { s in
      guard s.started else { return }
      s.crumbs.append(crumb)
      if s.crumbs.count > s.maxBreadcrumbs { s.crumbs.removeFirst(s.crumbs.count - s.maxBreadcrumbs) }
    }
  }

  /// Sends what is queued now (also retried on the next start).
  public func flush() async {
    await state.value.starting?.value
    await kick()?.value
  }

  // MARK: API breadcrumbs

  /// Performs `perform` and, while reporting is started, records the call as an `api` breadcrumb: method, path, query
  /// keys (no values, no host), status, error code and duration. Calls to `/crashes/v1/` and `/analytics/v1/` are not
  /// recorded.
  func recording(
    _ request: URLRequest,
    _ perform: () async throws -> (Data, URLResponse)
  ) async throws -> (Data, URLResponse) {
    guard isStarted, let requestURL = request.url, !requestURL.path.contains("/crashes/v1/"),
      !requestURL.path.contains("/analytics/v1/")
    else {
      return try await perform()
    }
    let t0 = Date()
    let at = crashIsoNow()
    let method = (request.httpMethod ?? "GET").uppercased()
    let path = breadcrumbURL(requestURL)
    do {
      let result = try await perform()
      let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
      var data: JSONObject = [
        "method": .string(method), "url": .string(path), "status": .integer(status),
        "ms": .integer(Int(Date().timeIntervalSince(t0) * 1000)),
      ]
      if status >= 400, let code = errorCode(in: result.0) { data["error_code"] = .string(code) }
      addBreadcrumb(
        Breadcrumb(
          type: "api", message: "\(method) \(path) \(status)", level: status >= 400 ? .error : .info, data: data, at: at
        )
      )
      return result
    } catch {
      addBreadcrumb(
        Breadcrumb(
          type: "api", message: "\(method) \(path) failed", level: .error,
          data: [
            "method": .string(method), "url": .string(path), "status": 0,
            "error": .string(String(describing: error)),
          ],
          at: at
        )
      )
      throw error
    }
  }

  // MARK: Queue

  var queuedReports: [CrashReport] { state.value.queue }

  private func makeReport(
    _ exception: CrashReport.Exception, handled: Bool, context: JSONObject?, fingerprint: [String]?
  ) -> (CrashReport, BeforeSend?) {
    state.withValue { s in
      (
        CrashReport(
          platform: crashPlatform, release: s.release, environment: s.environment, installID: s.installID,
          at: crashIsoNow(), handled: handled, exception: exception, breadcrumbs: s.crumbs, device: deviceInfo(),
          context: context ?? [:], fingerprint: fingerprint
        ),
        s.beforeSend
      )
    }
  }

  /// Builds the report, runs `beforeSend` and writes the queue to disk synchronously. Returns whether it was queued.
  @discardableResult
  private func store(
    _ exception: CrashReport.Exception, handled: Bool, context: JSONObject?, fingerprint: [String]?
  ) -> Bool {
    let (built, beforeSend) = makeReport(exception, handled: handled, context: context, fingerprint: fingerprint)
    let report: CrashReport? = if let beforeSend { beforeSend(built) } else { built }
    guard let report else { return false }
    state.withValue { s in
      s.queue.append(report)
      if s.queue.count > Self.maxQueue { s.queue.removeFirst(s.queue.count - Self.maxQueue) }
      Self.saveQueue(s.queue, in: s.directory)
    }
    return true
  }

  private func enqueue(
    _ exception: CrashReport.Exception, handled: Bool, context: JSONObject?, fingerprint: [String]?
  ) {
    if store(exception, handled: handled, context: context, fingerprint: fingerprint) { kick() }
  }

  /// An uncaught exception: the process is dying, so only write the report; it is sent on the next start.
  func recordUncaught(type: String, message: String, stack: String, mechanism: String) {
    guard isStarted else { return }
    store(
      CrashReport.Exception(type: type, message: message, stack: stack, mechanism: mechanism),
      handled: false, context: nil, fingerprint: nil
    )
  }

  func setHooked(_ hooked: Bool) { state.withValue { $0.hooked = hooked } }

  /// Starts sending the queue unless a send is already running; returns the running send.
  @discardableResult
  private func kick() -> Task<Void, Never>? {
    state.withValue { s in
      if let sending = s.sending { return sending }
      guard !s.disabled, !s.queue.isEmpty else { return nil }
      let task = Task { await self.sendQueue() }
      s.sending = task
      return task
    }
  }

  private func sendQueue() async {
    while true {
      let batch: [CrashReport] = state.withValue { s in
        let batch = s.disabled ? [] : Array(s.queue.prefix(Self.batchSize))
        if batch.isEmpty { s.sending = nil }
        return batch
      }
      if batch.isEmpty { return }
      let status: Int
      do {
        status = try await post("report", ["reports": batch])
      } catch {
        status = 0
      }
      let keepGoing = state.withValue { s -> Bool in
        switch status {
        case 403, 404:  // crash reporting is off for the project
          s.disabled = true
          s.queue = []
        case 200..<300, 400, 413, 429:  // sent, or refused for good: do not retry
          for report in batch {
            if let i = s.queue.firstIndex(of: report) { s.queue.remove(at: i) }
          }
        default:  // offline or the server is busy: kept on disk for the next start
          s.sending = nil
          return false
        }
        Self.saveQueue(s.queue, in: s.directory)
        return true
      }
      if !keepGoing { return }
    }
  }

  // Once a day per install and release, for crash-free users in Studio.
  private func sendSession() async {
    let (mark, file, body): (String, URL, AnyJSON) = state.withValue { s in
      let day = String(crashIsoNow().prefix(10))
      return (
        "\(day)|\(s.release ?? "")", s.directory.appendingPathComponent("session"),
        [
          "release": s.release.map(AnyJSON.string) ?? .null, "install_id": .string(s.installID),
          "environment": .string(s.environment),
        ]
      )
    }
    if (try? String(contentsOf: file, encoding: .utf8)) == mark { return }
    guard let status = try? await post("session", body) else { return }
    if status < 500 { try? Data(mark.utf8).write(to: file, options: .atomic) }
    if status == 404 || status == 403 { state.withValue { $0.disabled = true } }
  }

  private func post(_ path: String, _ body: some Encodable) async throws -> Int {
    try await sendJSON(fetch.value, url.appendingPathComponent(path), headers: headers, body: body)
  }

  // MARK: Disk

  private static func loadInstallID(in directory: URL) -> String {
    let file = directory.appendingPathComponent("install")
    if let id = try? String(contentsOf: file, encoding: .utf8), !id.isEmpty { return id }
    let id = UUID().uuidString.lowercased()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(id.utf8).write(to: file, options: .atomic)
    return id
  }

  static func loadQueue(in directory: URL) -> [CrashReport] {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("queue.json")) else { return [] }
    return (try? JSONDecoder().decode([CrashReport].self, from: data)) ?? []
  }

  private static func saveQueue(_ queue: [CrashReport], in directory: URL) {
    let file = directory.appendingPathComponent("queue.json")
    if queue.isEmpty {
      try? FileManager.default.removeItem(at: file)
      return
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? JSONEncoder().encode(queue).write(to: file, options: .atomic)
  }
}

// MARK: - Uncaught exceptions

/// The process-wide `NSSetUncaughtExceptionHandler` hook shared by every started ``CrashesClient``. The previous
/// handler is kept and called after the reports are written.
enum UncaughtExceptions {
  private struct Weak { weak var client: CrashesClient? }

  #if canImport(ObjectiveC)
    private struct State {
      var clients: [Weak] = []
      var installed = false
      var previous: (@convention(c) (NSException) -> Void)?
    }
    nonisolated(unsafe) private static var stateStorage = State()
    private static let lock = NSRecursiveLock()

    private static func withState<T>(_ body: (inout State) -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body(&stateStorage)
    }

    static func add(_ client: CrashesClient) {
      client.setHooked(true)
      withState { s in
        s.clients.removeAll { $0.client == nil || $0.client === client }
        s.clients.append(Weak(client: client))
        if !s.installed {
          s.previous = NSGetUncaughtExceptionHandler()
          NSSetUncaughtExceptionHandler { exception in UncaughtExceptions.handle(exception) }
          s.installed = true
        }
      }
    }

    static func remove(_ client: CrashesClient) {
      client.setHooked(false)
      withState { s in
        s.clients.removeAll { $0.client == nil || $0.client === client }
        if s.clients.isEmpty, s.installed {
          NSSetUncaughtExceptionHandler(s.previous)
          s.previous = nil
          s.installed = false
        }
      }
    }

    private static func handle(_ exception: NSException) {
      let (clients, previous) = withState { s in (s.clients.compactMap(\.client), s.previous) }
      for client in clients {
        client.recordUncaught(
          type: exception.name.rawValue, message: exception.reason ?? "",
          stack: exception.callStackSymbols.joined(separator: "\n"), mechanism: "NSUncaughtExceptionHandler"
        )
      }
      previous?(exception)
    }
  #else
    // No Objective-C runtime: errors are reported with captureError(_:); there is no uncaught exception hook.
    static func add(_ client: CrashesClient) {}
    static func remove(_ client: CrashesClient) {}
  #endif
}

// MARK: - StitchClient

extension StitchClient {
  /// The default directory for ``crashes``: one folder per project (see ``CrashesClient/defaultDirectory(namespace:)``).
  static func crashesDirectory(for url: URL) -> URL {
    CrashesClient.defaultDirectory(namespace: stitchNamespace(for: url))
  }
}

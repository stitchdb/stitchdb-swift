import ConcurrencyExtras
public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Feature flags and remote config (`stitchdb.flags`, Studio › Integrations › Feature flags): turn features on for some
// users (a plan, a segment, a percentage) and read values your app uses at runtime, changed in Studio without a release.
// Flags are evaluated by StitchDB for the signed-in user (from the session, so a user cannot pretend to be on another
// plan) and the attributes the app sends. The last values are kept on the device, so `get` answers at once on the next
// start and keeps working offline; the default you pass is used until a value is known.
// Local layout (one directory per project): `flags.json` the last values, `anon` the id that keeps percentage rollouts
// stable for a visitor who is not signed in.

/// A request to `/flags/v1` failed: `status` is the HTTP status (0 without an answer). The last values stay readable.
public struct FlagsError: Error, LocalizedError, Sendable, Equatable, ServiceError {
  public let message: String
  public let status: Int
  public let code: String?

  public init(message: String, status: Int, code: String? = nil) {
    self.message = message
    self.status = status
    self.code = code
  }

  public var errorDescription: String? { message }
}

/// A flag's value, which variation it is and why (`off`, `rule:0`, `default`, `default:split`, …).
public struct FlagValue: Codable, Sendable, Equatable {
  public let value: AnyJSON
  public let variation: Int
  public let reason: String

  public init(value: AnyJSON, variation: Int = 0, reason: String = "") {
    self.value = value
    self.variation = variation
    self.reason = reason
  }

  enum CodingKeys: String, CodingKey { case value, variation, reason }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    value = try c.decodeIfPresent(AnyJSON.self, forKey: .value) ?? .null
    variation = try c.decodeIfPresent(Int.self, forKey: .variation) ?? 0
    reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
  }
}

/// A user for server-side evaluation with the service key.
public struct FlagUser: Encodable, Sendable, Equatable {
  public var id: String
  public var email: String?
  public var role: String?
  public var appMetadata: JSONObject?
  public var userMetadata: JSONObject?

  public init(
    id: String, email: String? = nil, role: String? = nil, appMetadata: JSONObject? = nil,
    userMetadata: JSONObject? = nil
  ) {
    self.id = id
    self.email = email
    self.role = role
    self.appMetadata = appMetadata
    self.userMetadata = userMetadata
  }

  enum CodingKeys: String, CodingKey {
    case id, email, role
    case appMetadata = "app_metadata"
    case userMetadata = "user_metadata"
  }
}

private struct FlagsAnswer: Decodable {
  let flags: [String: FlagValue]?
  let version: Int?
  let userID: String?

  enum CodingKeys: String, CodingKey {
    case flags, version
    case userID = "user_id"
  }
}

private struct FlagsCache: Codable {
  var flags: [String: FlagValue]
  var version: Int
  var userID: String?

  enum CodingKeys: String, CodingKey {
    case flags, version
    case userID = "user_id"
  }
}

private struct EvaluateBody: Encodable {
  var user: FlagUser?
  var attributes: JSONObject
  var keys: [String]?
  var anonID: String?

  enum CodingKeys: String, CodingKey {
    case user, attributes, keys
    case anonID = "anon_id"
  }
}

/// Feature flags and remote config. Use the one on ``StitchClient/flags``.
///
/// ```swift
/// try await stitchdb.flags.load(attributes: ["app_version": "2.4.1", "country": "DE"])
/// if stitchdb.flags.isOn("new-checkout") { showNewCheckout() }
/// let limit = stitchdb.flags.get("upload-limit-mb", default: 10)
/// let token = stitchdb.flags.onChange { keys in render() }
/// ```
public final class FlagsClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch
  typealias AuthChanges = AnalyticsClient.AuthChanges

  struct State {
    var values: [String: FlagValue] = [:]
    var version = 0
    var userID: String?
    var attributes: JSONObject = [:]
    var keys: [String]?
    var refreshInterval: TimeInterval = 60
    var loaded = false
    var listeners: [Int: @Sendable ([String]) -> Void] = [:]
    var nextListener = 0
    var timer: Task<Void, Never>?
    var inflight: Task<[String: FlagValue], any Error>?
    var anonID: String?
  }

  let http: ServiceHTTP
  private let directory: URL
  private let state = LockIsolated(State())
  private let stopAuth = LockIsolated<(@Sendable () -> Void)?>(nil)

  init(url: URL, headers: [String: String], directory: URL, authChanges: AuthChanges? = nil, fetch: Fetch? = nil) {
    http = ServiceHTTP(url: url, headers: headers, fetch: fetch)
    self.directory = directory
    if let data = try? Data(contentsOf: directory.appendingPathComponent("flags.json")),
      let cached = try? JSONDecoder().decode(FlagsCache.self, from: data)
    {
      state.withValue {
        $0.values = cached.flags
        $0.version = cached.version
        $0.userID = cached.userID
      }
    }
    if let authChanges {
      // a sign-in or sign-out changes who the flags are for
      let stop = authChanges { [weak self] in
        guard let self, self.state.loaded else { return }
        Task { _ = try? await self.refresh() }
      }
      stopAuth.setValue(stop)
    }
  }

  deinit {
    stopAuth.value?()
    state.timer?.cancel()
  }

  /// Application Support (Caches on tvOS) on Apple platforms, the temporary directory elsewhere; one folder per project.
  public static func defaultDirectory(namespace: String) -> URL {
    stitchDataDirectory("flags", namespace: namespace)
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  // MARK: Loading

  /// Fetches the flags for the current user. Call it once at start; after that they refresh every `refreshInterval`
  /// seconds (0: only when you call ``refresh()``), on sign-in and on sign-out.
  ///
  /// - Parameters:
  ///   - attributes: What rules can target as `attr.<name>` (app version, country, platform …). Not trusted: fine for
  ///     targeting, not for access control.
  ///   - keys: Only these flags (default all the app may see).
  @discardableResult
  public func load(attributes: JSONObject? = nil, keys: [String]? = nil, refreshInterval: TimeInterval? = nil)
    async throws -> [String: FlagValue]
  {
    let every = state.withValue { s -> TimeInterval in
      if let attributes { s.attributes.merge(attributes) { $1 } }
      if let keys { s.keys = keys }
      if let refreshInterval { s.refreshInterval = refreshInterval }
      s.loaded = true
      s.timer?.cancel()
      s.timer = nil
      return s.refreshInterval
    }
    if every > 0 {
      let timer = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
          guard !Task.isCancelled, let self else { return }
          _ = try? await self.refresh()
        }
      }
      state.withValue { $0.timer = timer }
    }
    return try await refresh()
  }

  /// Fetches again now. Calls made while a fetch is running share it.
  @discardableResult
  public func refresh() async throws -> [String: FlagValue] {
    let task = state.withValue { s -> Task<[String: FlagValue], any Error> in
      if let running = s.inflight { return running }
      let t = Task { [self] in
        defer { state.withValue { $0.inflight = nil } }
        return try await fetchFlags()
      }
      s.inflight = t
      return t
    }
    return try await task.value
  }

  /// Sets attributes rules target (merged into the current ones) and fetches again.
  @discardableResult
  public func setAttributes(_ attributes: JSONObject) async throws -> [String: FlagValue] {
    state.withValue { $0.attributes.merge(attributes) { $1 } }
    return try await refresh()
  }

  /// Stops refreshing (the values stay readable).
  public func stop() {
    state.withValue {
      $0.timer?.cancel()
      $0.timer = nil
    }
  }

  private func fetchFlags() async throws -> [String: FlagValue] {
    let (attributes, keys) = state.withValue { ($0.attributes, $0.keys) }
    let body = EvaluateBody(user: nil, attributes: attributes, keys: keys, anonID: anonID())
    let answer = try await http.send("POST", ["evaluate"], body: body, as: FlagsAnswer.self, error: FlagsError.self)
    let values = answer.flags ?? [:]
    let (changed, listeners) = state.withValue { s -> ([String], [@Sendable ([String]) -> Void]) in
      let previous = s.values
      s.values = values
      s.version = answer.version ?? 0
      s.userID = answer.userID
      let keys = Set(previous.keys).union(values.keys)
      let changed = keys.filter { previous[$0]?.value != values[$0]?.value }.sorted()
      return (changed, Array(s.listeners.values))
    }
    save()
    if !changed.isEmpty { for listener in listeners { listener(changed) } }
    return values
  }

  private func save() {
    let cache = state.withValue { FlagsCache(flags: $0.values, version: $0.version, userID: $0.userID) }
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent("flags.json"), options: .atomic)
  }

  /// The id that keeps percentage rollouts stable for a visitor who is not signed in (kept on the device).
  func anonID() -> String {
    state.withValue { s in
      if let id = s.anonID { return id }
      let file = directory.appendingPathComponent("anon")
      if let data = try? Data(contentsOf: file), let id = String(data: data, encoding: .utf8), !id.isEmpty {
        s.anonID = id
        return id
      }
      let id = UUID().uuidString.lowercased()
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? Data(id.utf8).write(to: file, options: .atomic)
      s.anonID = id
      return id
    }
  }

  // MARK: Reading

  /// A flag's value, or nil while it is not known (not loaded yet, deleted, or server-only).
  public func value(_ key: String) -> AnyJSON? {
    guard let v = state.values[key]?.value, v != .null else { return nil }
    return v
  }

  /// A flag's value as `T`, or `fallback` while it is not known or of another type.
  public func get<T: Decodable>(_ key: String, default fallback: T) -> T {
    guard let v = value(key) else { return fallback }
    if T.self == Double.self, let d = v.doubleValue ?? v.intValue.map(Double.init) { return d as? T ?? fallback }
    return (try? v.decode(as: T.self)) ?? fallback
  }

  /// Whether a boolean flag is on (false when it is not known).
  public func isOn(_ key: String) -> Bool { value(key)?.boolValue == true }

  /// The value, which variation it is and why, for debugging.
  public func detail(_ key: String) -> FlagValue? { state.values[key] }

  /// Every known flag's value.
  public func all() -> JSONObject { state.values.mapValues(\.value) }

  /// The definition version the values come from (grows with every change in Studio).
  public var configVersion: Int { state.version }

  /// Called with the changed keys whenever a refresh changes values. Keep the token: listening stops when it is
  /// cancelled or released.
  public func onChange(_ callback: @escaping @Sendable (_ keys: [String]) -> Void) -> ObservationToken {
    let id = state.withValue { s -> Int in
      s.nextListener += 1
      s.listeners[s.nextListener] = callback
      return s.nextListener
    }
    return ObservationToken { [weak self] in self?.state.withValue { _ = $0.listeners.removeValue(forKey: id) } }
  }

  // MARK: Server side

  /// Server side, with the service key: the flags for any user, including flags marked server-only.
  public func evaluate(
    user: FlagUser?, attributes: JSONObject = [:], keys: [String]? = nil, anonID: String? = nil
  ) async throws -> [String: FlagValue] {
    let body = EvaluateBody(user: user, attributes: attributes, keys: keys, anonID: anonID)
    return try await http.send("POST", ["evaluate"], body: body, as: FlagsAnswer.self, error: FlagsError.self).flags
      ?? [:]
  }
}

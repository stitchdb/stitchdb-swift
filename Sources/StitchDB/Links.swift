import ConcurrencyExtras
public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Deep links and short links (`stitchdb.links`, Studio › Links): `https://<project host or your domain>/l/<code>` opens
// your app on the right screen when it is installed (iOS Universal Links), and otherwise sends people to the App Store,
// Google Play or a web page. The app resolves the link it was opened with to its path and data, and on its first launch
// after an install can ask which link led to the install (deferred deep link, best effort).
// Local layout (one directory per project): `deferred-checked` present once ``LinksClient/deferred(platform:referrer:force:)``
// got an answer on this install.

/// A request to `/links/v1` failed: `status` is the HTTP status (410 for an expired or turned-off link, 0 without an
/// answer).
public struct LinksError: Error, LocalizedError, Sendable, Equatable {
  public let message: String
  public let status: Int

  public init(message: String, status: Int) {
    self.message = message
    self.status = status
  }

  public var errorDescription: String? { message }
}

/// The platform a link is opened on (it picks the store and is counted in Studio).
public enum LinkPlatform: String, Codable, Sendable {
  case ios, android, web
}

/// What the app gets for a link.
public struct AppLink: Codable, Sendable, Equatable {
  public let code: String
  /// The short link.
  public let url: String
  /// The screen to show, as you stored it (for example `/product/42`), or nil for the start screen.
  public let path: String?
  /// The data stored with the link.
  public let data: JSONObject
  /// ``LinksClient/deferred(platform:referrer:force:)`` only: how the install was matched to the click (`referrer` or
  /// `network`).
  public let matchedBy: String?

  public init(code: String, url: String, path: String? = nil, data: JSONObject = [:], matchedBy: String? = nil) {
    self.code = code
    self.url = url
    self.path = path
    self.data = data
    self.matchedBy = matchedBy
  }

  enum CodingKeys: String, CodingKey {
    case code, url, path, data
    case matchedBy = "matched_by"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    code = try c.decode(String.self, forKey: .code)
    url = try c.decode(String.self, forKey: .url)
    path = try c.decodeIfPresent(String.self, forKey: .path)
    data = try c.decodeIfPresent(JSONObject.self, forKey: .data) ?? [:]
    matchedBy = try c.decodeIfPresent(String.self, forKey: .matchedBy)
  }
}

/// A new link, or the changes to one. Fields left nil are not sent (on ``LinksClient/update(_:_:)``: not changed); pass
/// an empty string to clear a text field, and `removeExpiry` to make a link never expire.
public struct LinkInput: Encodable, Sendable, Equatable {
  /// The screen the app shows (a path your router knows).
  public var path: String?
  /// Up to 4 KB of JSON for the app.
  public var data: JSONObject?
  /// Service key only: choose the code (letters, digits, `_` and `-`); default a random 7-letter code.
  public var code: String?
  /// Where people on a computer go (default: the project's web page).
  public var webURL: String?
  /// Instead of the App Store when the app is not installed.
  public var iosURL: String?
  /// Instead of Google Play when the app is not installed.
  public var androidURL: String?
  /// Shown when the link is shared in chats and social posts.
  public var title: String?
  public var description: String?
  public var imageURL: String?
  public var expiresAt: Date?
  /// Sends `expires_at: null` (the link no longer expires).
  public var removeExpiry: Bool
  public var disabled: Bool?

  public init(
    path: String? = nil, data: JSONObject? = nil, code: String? = nil, webURL: String? = nil, iosURL: String? = nil,
    androidURL: String? = nil, title: String? = nil, description: String? = nil, imageURL: String? = nil,
    expiresAt: Date? = nil, removeExpiry: Bool = false, disabled: Bool? = nil
  ) {
    self.path = path
    self.data = data
    self.code = code
    self.webURL = webURL
    self.iosURL = iosURL
    self.androidURL = androidURL
    self.title = title
    self.description = description
    self.imageURL = imageURL
    self.expiresAt = expiresAt
    self.removeExpiry = removeExpiry
    self.disabled = disabled
  }

  enum CodingKeys: String, CodingKey {
    case path, data, code, title, description, disabled
    case webURL = "web_url"
    case iosURL = "ios_url"
    case androidURL = "android_url"
    case imageURL = "image_url"
    case expiresAt = "expires_at"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(path, forKey: .path)
    try c.encodeIfPresent(data, forKey: .data)
    try c.encodeIfPresent(code, forKey: .code)
    try c.encodeIfPresent(webURL, forKey: .webURL)
    try c.encodeIfPresent(iosURL, forKey: .iosURL)
    try c.encodeIfPresent(androidURL, forKey: .androidURL)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(description, forKey: .description)
    try c.encodeIfPresent(imageURL, forKey: .imageURL)
    if let expiresAt {
      try c.encode(linkIsoString(expiresAt), forKey: .expiresAt)
    } else if removeExpiry {
      try c.encodeNil(forKey: .expiresAt)
    }
    try c.encodeIfPresent(disabled, forKey: .disabled)
  }
}

/// A short link as Studio shows it.
public struct Link: Codable, Sendable, Equatable {
  public let code: String
  public let url: String
  public let path: String?
  public let data: JSONObject
  public let webURL: String?
  public let iosURL: String?
  public let androidURL: String?
  public let title: String?
  public let description: String?
  public let imageURL: String?
  /// ISO 8601 time, or nil when the link does not expire.
  public let expiresAt: String?
  public let disabled: Bool
  /// `studio`, `api` or `user`.
  public let source: String?
  /// The user who made the link (``LinksClient/create(_:)`` signed in).
  public let createdBy: String?
  public let clicks: Int
  public let opens: Int
  public let installs: Int
  public let lastClickAt: String?
  public let createdAt: String?
  public let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case code, url, path, data, title, description, disabled, source, clicks, opens, installs
    case webURL = "web_url"
    case iosURL = "ios_url"
    case androidURL = "android_url"
    case imageURL = "image_url"
    case expiresAt = "expires_at"
    case createdBy = "created_by"
    case lastClickAt = "last_click_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    code = try c.decode(String.self, forKey: .code)
    url = try c.decode(String.self, forKey: .url)
    path = try c.decodeIfPresent(String.self, forKey: .path)
    data = try c.decodeIfPresent(JSONObject.self, forKey: .data) ?? [:]
    webURL = try c.decodeIfPresent(String.self, forKey: .webURL)
    iosURL = try c.decodeIfPresent(String.self, forKey: .iosURL)
    androidURL = try c.decodeIfPresent(String.self, forKey: .androidURL)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
    expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    source = try c.decodeIfPresent(String.self, forKey: .source)
    createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
    clicks = try c.decodeIfPresent(Int.self, forKey: .clicks) ?? 0
    opens = try c.decodeIfPresent(Int.self, forKey: .opens) ?? 0
    installs = try c.decodeIfPresent(Int.self, forKey: .installs) ?? 0
    lastClickAt = try c.decodeIfPresent(String.self, forKey: .lastClickAt)
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }
}

/// A page of ``LinksClient/list(search:limit:offset:)``.
public struct LinkList: Codable, Sendable, Equatable {
  public let links: [Link]
  public let total: Int
}

/// One link with its clicks per day, platform, country, where people went and referrers.
public struct LinkStats: Codable, Sendable, Equatable {
  public struct Day: Codable, Sendable, Equatable {
    /// `2026-10-26`.
    public let day: String
    public let clicks: Int
    public let opens: Int
    public let installs: Int
  }

  /// One row of a breakdown: the value (`ios`, `DE`, …; empty when unknown) and its count.
  public struct Count: Codable, Sendable, Equatable {
    public let k: String
    public let n: Int
  }

  public let link: Link
  public let days: Int
  public let daily: [Day]
  public let platforms: [Count]
  public let countries: [Count]
  public let outcomes: [Count]
  public let referrers: [Count]
}

private struct DeferredAnswer: Decodable {
  let match: AppLink?
}

private struct DeletedAnswer: Decodable {
  let deleted: String?
}

/// `2026-12-01T00:00:00.000Z`.
private func linkIsoString(_ date: Date) -> String {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.string(from: date)
}

/// Deep links and short links. Use the one on ``StitchClient/links``.
///
/// ```swift
/// // the app was opened by a link (onOpenURL, or the NSUserActivity of a Universal Link)
/// if let link = try await stitchdb.links.resolve(url) { router.open(link.path, link.data) }
///
/// // first launch after an install: the link that led to it (asked once per install)
/// if let first = try await stitchdb.links.deferred() { router.open(first.path, first.data) }
///
/// // make a link: signed-in users when the project allows it, any link with the service key
/// let made = try await stitchdb.links.create(LinkInput(path: "/invite/7", data: ["from": "ana"]))
/// share(made.url)
/// ```
public final class LinksClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  private let url: URL
  private let headers: [String: String]
  private let directory: URL
  private let fetch = LockIsolated<Fetch?>(nil)

  init(url: URL, headers: [String: String], directory: URL, fetch: Fetch? = nil) {
    self.url = url
    self.headers = headers
    self.directory = directory
    self.fetch.setValue(fetch)
  }

  /// Application Support (Caches on tvOS) on Apple platforms, the temporary directory elsewhere; one folder per project.
  public static func defaultDirectory(namespace: String) -> URL {
    stitchDataDirectory("links", namespace: namespace)
  }

  func setFetch(_ fetch: @escaping Fetch) { self.fetch.setValue(fetch) }

  /// The platform ``resolve(_:platform:)`` sends by default: `ios` on iOS, iPadOS and visionOS, none elsewhere.
  public static var currentPlatform: LinkPlatform? {
    #if os(iOS) || os(visionOS)
      return .ios
    #else
      return nil
    #endif
  }

  // MARK: Codes

  /// The code of a short link (`https://…/l/<code>`, a trailing slash and the query are ignored), or nil for any other
  /// URL. A bare code is returned as is. The host is not checked (a link can be on your own domain).
  public static func codeFrom(_ urlOrCode: String) -> String? {
    let s = urlOrCode.trimmingCharacters(in: .whitespacesAndNewlines)
    if isValidCode(s) { return s }
    guard let components = URLComponents(string: s), components.scheme != nil, components.host != nil else {
      return nil
    }
    var parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
    if parts.last == "" { parts.removeLast() }
    guard parts.count == 3, parts[0].isEmpty, parts[1] == "l" else { return nil }
    let code = String(parts[2])
    return isValidCode(code) ? code : nil
  }

  /// The code of a short link URL, or nil.
  public static func codeFrom(_ url: URL) -> String? { codeFrom(url.absoluteString) }

  /// `^[A-Za-z0-9_-]{1,64}$`.
  static func isValidCode(_ s: String) -> Bool {
    let chars = Array(s.unicodeScalars)
    guard !chars.isEmpty, chars.count <= 64 else { return false }
    return chars.allSatisfy {
      ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
    }
  }

  // MARK: App

  /// The link the app was opened with: its path and data (counted as an open in Studio). Nil, without a request, for a
  /// URL that is not a short link; an expired or turned-off link throws ``LinksError`` with status 410.
  public func resolve(_ urlOrCode: String, platform: LinkPlatform? = LinksClient.currentPlatform) async throws -> AppLink? {
    guard let code = Self.codeFrom(urlOrCode) else { return nil }
    var query: [URLQueryItem] = []
    if let platform { query.append(URLQueryItem(name: "platform", value: platform.rawValue)) }
    return try await request("GET", ["resolve", code], query: query, as: AppLink.self)
  }

  /// The link the app was opened with (see ``resolve(_:platform:)``).
  public func resolve(_ url: URL, platform: LinkPlatform? = LinksClient.currentPlatform) async throws -> AppLink? {
    try await resolve(url.absoluteString, platform: platform)
  }

  #if canImport(Darwin)
    /// The Universal Link the app was continued with (`NSUserActivity.webpageURL`), or nil for any other activity.
    public func resolve(
      userActivity: NSUserActivity, platform: LinkPlatform? = LinksClient.currentPlatform
    ) async throws -> AppLink? {
      guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
        return nil
      }
      return try await resolve(url, platform: platform)
    }
  #endif

  /// First launch after an install: the link that led to it, or nil. The click is matched by network and platform within
  /// 2 hours (best effort, each click is handed out once); `referrer` is an Android Play install referrer (an exact match).
  ///
  /// Asked once per install: after an answer this returns nil without a request (remembered on the device). `force`
  /// asks again.
  public func deferred(platform: LinkPlatform = .ios, referrer: String? = nil, force: Bool = false) async throws
    -> AppLink?
  {
    let flag = directory.appendingPathComponent("deferred-checked")
    if !force, FileManager.default.fileExists(atPath: flag.path) { return nil }
    var body: JSONObject = ["platform": .string(platform.rawValue)]
    if let referrer { body["referrer"] = .string(referrer) }
    let answer = try await request("POST", ["deferred"], body: body, as: DeferredAnswer.self)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data("1".utf8).write(to: flag, options: .atomic)
    return answer.match
  }

  /// Whether ``deferred(platform:referrer:force:)`` already got an answer on this install.
  public var isDeferredChecked: Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent("deferred-checked").path)
  }

  // MARK: Manage

  /// Makes a short link (signed-in users when the project allows it in Studio › Links, any link with the service key).
  /// Throws ``LinksError`` with 403 (not allowed), 402 (plan limit) or 409 (code taken).
  public func create(_ link: LinkInput) async throws -> Link {
    try await request("POST", ["links"], body: link, as: Link.self)
  }

  /// Links, newest first (service key).
  public func list(search: String? = nil, limit: Int? = nil, offset: Int? = nil) async throws -> LinkList {
    var query: [URLQueryItem] = []
    if let search, !search.isEmpty { query.append(URLQueryItem(name: "q", value: search)) }
    if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let offset { query.append(URLQueryItem(name: "offset", value: String(offset))) }
    return try await request("GET", ["links"], query: query, as: LinkList.self)
  }

  /// One link with its clicks per day, platform, country, where people went and referrers (service key).
  public func get(_ code: String, days: Int? = nil) async throws -> LinkStats {
    let query = days.map { [URLQueryItem(name: "days", value: String($0))] } ?? []
    return try await request("GET", ["links", code], query: query, as: LinkStats.self)
  }

  /// Changes a link (service key): only the fields set in `patch`.
  public func update(_ code: String, _ patch: LinkInput) async throws -> Link {
    try await request("PATCH", ["links", code], body: patch, as: Link.self)
  }

  /// Deletes a link and its clicks (service key); returns the deleted code.
  @discardableResult
  public func remove(_ code: String) async throws -> String {
    try await request("DELETE", ["links", code], as: DeletedAnswer.self).deleted ?? code
  }

  // MARK: HTTP

  private func request<T: Decodable>(
    _ method: String, _ path: [String], query: [URLQueryItem] = [], as: T.Type
  ) async throws -> T {
    try await request(method, path, query: query, body: AnyJSON?.none, as: T.self)
  }

  private func request<T: Decodable>(
    _ method: String, _ path: [String], query: [URLQueryItem] = [], body: (some Encodable)?, as: T.Type
  ) async throws -> T {
    guard let fetch = fetch.value else { throw LinksError(message: "The client is not ready", status: 0) }
    var full = url
    for part in path { full.appendPathComponent(part) }
    if !query.isEmpty, var c = URLComponents(url: full, resolvingAgainstBaseURL: false) {
      c.queryItems = query
      full = c.url ?? full
    }
    var request = URLRequest(url: full)
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await fetch(request)
    } catch {
      throw LinksError(message: error.localizedDescription, status: 0)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let json = (try? JSONDecoder().decode(AnyJSON.self, from: data))?.objectValue
      let message = json?["message"]?.stringValue ?? json?["msg"]?.stringValue ?? "Request failed (\(status))"
      throw LinksError(message: message, status: status)
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw LinksError(message: "Unexpected answer: \(error)", status: status)
    }
  }
}

// MARK: - StitchClient

extension StitchClient {
  /// The default directory for ``links``: one folder per project (see ``LinksClient/defaultDirectory(namespace:)``).
  static func linksDirectory(for url: URL) -> URL {
    LinksClient.defaultDirectory(namespace: stitchNamespace(for: url))
  }
}

public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// The app's public status page (`stitchdb.status`, turned on in Studio): whether the API, Auth, Storage, Edge Functions,
// Realtime, the database and your own URLs are up, 90 days of uptime, incidents and maintenance, and e-mail updates.
// No key is needed and nothing here is private.

/// A request to `/status/v1` failed: `status` is the HTTP status (404 when the page is off, 0 without an answer).
public struct StatusError: Error, LocalizedError, Sendable, Equatable, ServiceError {
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

/// One day of a component's history.
public struct StatusDay: Decodable, Sendable, Equatable {
  public let day: String
  /// `operational`, `degraded`, `down` or `unknown`.
  public let status: String
  public let uptime: Double?
  public let downMinutes: Int?

  enum CodingKeys: String, CodingKey {
    case day, status, uptime
    case downMinutes = "down_minutes"
  }
}

/// A component of the page (the API, Auth, a URL of yours …).
public struct StatusComponent: Decodable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let description: String?
  /// `operational`, `degraded`, `down`, `maintenance` or `unknown`.
  public let status: String
  public let since: String?
  public let responseMs: Double?
  public let checkedAt: String?
  /// Percent of checks that answered in the last 90 days, or nil before the first check.
  public let uptime90d: Double?
  /// One entry per day, oldest first.
  public let history: [StatusDay]

  enum CodingKeys: String, CodingKey {
    case id, name, description, status, since, history
    case responseMs = "response_ms"
    case checkedAt = "checked_at"
    case uptime90d = "uptime_90d"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    since = try c.decodeIfPresent(String.self, forKey: .since)
    responseMs = try c.decodeIfPresent(Double.self, forKey: .responseMs)
    checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt)
    uptime90d = try c.decodeIfPresent(Double.self, forKey: .uptime90d)
    history = try c.decodeIfPresent([StatusDay].self, forKey: .history) ?? []
  }
}

/// An incident or a maintenance window. `raw` has every field as sent.
public struct StatusIncident: Decodable, Sendable, Equatable {
  public struct Update: Decodable, Sendable, Equatable {
    public let status: String
    public let message: String
    public let at: String
  }

  public let id: String
  public let title: String
  /// `minor`, `major`, `critical` or `maintenance`.
  public let impact: String
  /// `investigating`, `identified`, `monitoring`, `resolved`, `scheduled`, `in_progress` or `completed`.
  public let status: String
  public let components: [String]
  public let startsAt: String?
  public let endsAt: String?
  public let updates: [Update]
  public let raw: JSONObject

  enum CodingKeys: String, CodingKey {
    case id, title, impact, status, components, updates
    case startsAt = "starts_at"
    case endsAt = "ends_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    impact = try c.decodeIfPresent(String.self, forKey: .impact) ?? ""
    status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    components = try c.decodeIfPresent([String].self, forKey: .components) ?? []
    startsAt = try c.decodeIfPresent(String.self, forKey: .startsAt)
    endsAt = try c.decodeIfPresent(String.self, forKey: .endsAt)
    updates = try c.decodeIfPresent([Update].self, forKey: .updates) ?? []
    raw = try JSONObject(from: decoder)
  }
}

/// The whole page.
public struct StatusSummary: Decodable, Sendable, Equatable {
  public let title: String
  public let description: String?
  public let url: String?
  /// `operational`, `degraded`, `down`, `maintenance` or `unknown`.
  public let overall: String
  public let overallLabel: String
  public let components: [StatusComponent]
  public let incidents: [StatusIncident]
  public let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case title, description, url, overall, components, incidents
    case overallLabel = "overall_label"
    case updatedAt = "updated_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    description = try c.decodeIfPresent(String.self, forKey: .description)
    url = try c.decodeIfPresent(String.self, forKey: .url)
    overall = try c.decodeIfPresent(String.self, forKey: .overall) ?? "unknown"
    overallLabel = try c.decodeIfPresent(String.self, forKey: .overallLabel) ?? ""
    components = try c.decodeIfPresent([StatusComponent].self, forKey: .components) ?? []
    incidents = try c.decodeIfPresent([StatusIncident].self, forKey: .incidents) ?? []
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }
}

/// The answer of ``StatusClient/subscribe(email:)``.
public struct StatusSubscribeResult: Decodable, Sendable, Equatable {
  public let ok: Bool
  public let message: String

  enum CodingKeys: String, CodingKey { case ok, message }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
    message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
  }
}

/// The public status page. Use the one on ``StitchClient/status``.
///
/// ```swift
/// let page = try await stitchdb.status.get()
/// if page.overall != "operational" { showBanner(page.overallLabel) }
/// try await stitchdb.status.subscribe(email: "ana@example.com") // she gets a link to confirm
/// ```
public final class StatusClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  let http: ServiceHTTP

  init(url: URL, fetch: Fetch? = nil) {
    http = ServiceHTTP(url: url, headers: ["Accept": "application/json"], fetch: fetch)
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  /// The current state of every component, 90 days of history and the latest incidents (cached for about 30 s).
  public func get() async throws -> StatusSummary {
    try await http.send("GET", ["status.json"], as: StatusSummary.self, error: StatusError.self)
  }

  /// Subscribes an e-mail address to incident and maintenance updates. The address gets a link to confirm first; the
  /// answer is the same whether it was subscribed already or not. Needs e-mail updates turned on (otherwise 404).
  @discardableResult
  public func subscribe(email: String) async throws -> StatusSubscribeResult {
    try await http.send(
      "POST", ["subscribe"], body: ["email": email], as: StatusSubscribeResult.self, error: StatusError.self
    )
  }

  /// The public page (HTML) to link to.
  public var pageURL: URL { URL(string: http.url([]).absoluteString + "/") ?? http.url }

  /// The JSON ``get()`` reads, for other tools.
  public var jsonURL: URL { http.url(["status.json"]) }

  /// An SVG badge for a README or a site: the overall state, or one component's, with your own label.
  public func badgeURL(component: String? = nil, label: String? = nil) -> URL {
    http.url(["badge.svg"], query: queryItems([("component", component), ("label", label)]))
  }
}

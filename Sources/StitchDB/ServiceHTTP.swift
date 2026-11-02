import ConcurrencyExtras
import Foundation
import Helpers

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// The HTTP plumbing the platform modules share (push, purchases, search, jobs, flags, metering, collab, status, GraphQL):
// one base URL (`https://<ref>.p.stitchdb.com/<service>/v1`), the project headers and a fetch that adds the signed-in
// user's access token. Each module throws its own error type (``PushError``, ``JobsError``, …) with the HTTP status (0
// without an answer) and the `code` / `error_code` of the answer when it has one.

/// The errors of the platform modules: made from a message, the HTTP status and the error code of the answer.
protocol ServiceError: Error {
  init(message: String, status: Int, code: String?)
}

/// `{ "message": … }`, `{ "msg": … }` or `{ "error": … }` of an error answer, else `fallback`.
func serviceErrorMessage(_ json: JSONObject?, fallback: String) -> String {
  json?["message"]?.stringValue ?? json?["msg"]?.stringValue ?? json?["error"]?.stringValue ?? fallback
}

/// One path segment, percent-encoded (letters, digits and `-._~` stay as they are).
func encodePathSegment(_ s: String) -> String {
  var allowed = CharacterSet.alphanumerics
  allowed.insert(charactersIn: "-._~")
  return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// `2026-12-01T00:00:00.000Z`.
func serviceIsoString(_ date: Date) -> String {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.string(from: date)
}

struct ServiceHTTP: Sendable {
  typealias Fetch = CrashesClient.Fetch

  let url: URL
  let headers: [String: String]
  let fetch: LockIsolated<Fetch?>

  init(url: URL, headers: [String: String], fetch: Fetch? = nil) {
    self.url = url
    self.headers = headers
    self.fetch = LockIsolated(fetch)
  }

  func setFetch(_ fetch: @escaping Fetch) { self.fetch.setValue(fetch) }

  /// The URL of `path` (segments, each percent-encoded) with `query`.
  func url(_ path: [String], query: [URLQueryItem] = []) -> URL {
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var p = c.percentEncodedPath
    if p.hasSuffix("/") { p.removeLast() }
    for part in path { p += "/" + encodePathSegment(part) }
    c.percentEncodedPath = p
    if !query.isEmpty { c.queryItems = query }
    return c.url ?? url
  }

  /// Sends a request and returns the raw answer; a status outside 200-299 throws `E`.
  func raw<E: ServiceError>(
    _ method: String, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil,
    contentType: String = "application/json", headers extra: [String: String] = [:], error: E.Type
  ) async throws -> (Data, Int) {
    guard let fetch = fetch.value else { throw E(message: "The client is not ready", status: 0, code: nil) }
    var request = URLRequest(url: url(path, query: query))
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
    request.httpMethod = method
    if let body {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await fetch(request)
    } catch {
      throw E(message: error.localizedDescription, status: 0, code: nil)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let json = (try? JSONDecoder().decode(AnyJSON.self, from: data))?.objectValue
      let code = json?["error_code"]?.stringValue ?? json?["code"]?.stringValue
      throw E(message: serviceErrorMessage(json, fallback: "Request failed (\(status))"), status: status, code: code)
    }
    return (data, status)
  }

  /// Sends JSON (when `body` is set) and decodes the answer as `T`.
  func send<T: Decodable, E: ServiceError>(
    _ method: String, _ path: [String], query: [URLQueryItem] = [], body: (some Encodable)?, as: T.Type,
    headers extra: [String: String] = [:], error: E.Type
  ) async throws -> T {
    let encoded: Data?
    do {
      encoded = try body.map { try JSONEncoder().encode($0) }
    } catch {
      throw E(message: "Could not encode the request: \(error)", status: 0, code: nil)
    }
    let (data, status) = try await raw(method, path, query: query, body: encoded, headers: extra, error: E.self)
    let bytes = data.isEmpty ? Data("{}".utf8) : data
    do {
      return try JSONDecoder().decode(T.self, from: bytes)
    } catch {
      throw E(message: "Unexpected answer: \(error)", status: status, code: nil)
    }
  }

  /// A request without a body.
  func send<T: Decodable, E: ServiceError>(
    _ method: String, _ path: [String], query: [URLQueryItem] = [], as: T.Type, headers extra: [String: String] = [:],
    error: E.Type
  ) async throws -> T {
    try await send(method, path, query: query, body: AnyJSON?.none, as: T.self, headers: extra, error: E.self)
  }
}

/// Query items from optional values (nil values are left out).
func queryItems(_ pairs: [(String, String?)]) -> [URLQueryItem] {
  pairs.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
}

/// An encodable value as a JSON object (throws when it does not encode to an object).
func jsonObject(from value: some Encodable) throws -> JSONObject {
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONObject.self, from: data)
}

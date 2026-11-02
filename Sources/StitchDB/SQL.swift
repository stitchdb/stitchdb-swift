import ConcurrencyExtras
public import Foundation
public import Helpers
import RealtimeV2

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Serverless SQL (Studio › Database › Serverless SQL): Postgres queries over HTTPS, and interactive transactions over a
// WebSocket session, without a TCP connection.
//
// SERVER ONLY. The SQL key (`sdb_sql_…`) runs queries as the project's owner, past row level security, like the
// database connection string. Use it in a server, a script or a command line tool; never put it in an app you ship
// (anyone can read it out of the binary). Apps use ``StitchClient/from(_:)`` and ``StitchClient/rpc(_:params:count:)``.
//
// Values: booleans, int2/int4, float4/float8 and json/jsonb arrive as JSON values; int8, numeric, dates and times as
// the text Postgres prints (no precision is lost).

/// An error from the database (`code` is the Postgres SQLSTATE) or from the SQL endpoint.
public struct SqlError: Error, LocalizedError, Sendable, Equatable {
  public let message: String
  /// The HTTP status (0 without an answer; the close code for a closed session).
  public let status: Int
  public let code: String?
  public let detail: String?
  public let hint: String?
  public let position: String?
  /// For a transaction: which statement failed.
  public let index: Int?

  public init(
    message: String, status: Int = 0, code: String? = nil, detail: String? = nil, hint: String? = nil,
    position: String? = nil, index: Int? = nil
  ) {
    self.message = message
    self.status = status
    self.code = code
    self.detail = detail
    self.hint = hint
    self.position = position
    self.index = index
  }

  init(_ json: JSONObject?, status: Int, fallback: String) {
    func text(_ k: String) -> String? {
      guard let v = json?[k] else { return nil }
      return v.stringValue ?? v.intValue.map(String.init)
    }
    self.init(
      message: json?["message"]?.stringValue ?? fallback, status: status, code: text("code"), detail: text("detail"),
      hint: text("hint"), position: text("position"), index: json?["index"]?.intValue
    )
  }

  public var errorDescription: String? { message }
}

/// A column of a result.
public struct SqlField: Codable, Sendable, Equatable {
  public let name: String
  /// The Postgres type oid.
  public let dataTypeID: Int
}

/// The result of one statement. Rows are objects by column name, or arrays (column order as in `fields`) with
/// `arrayMode`.
public struct SqlResult: Decodable, Sendable, Equatable {
  public let command: String
  public let rowCount: Int?
  public let fields: [SqlField]
  public let rows: [AnyJSON]

  enum CodingKeys: String, CodingKey { case command, rowCount, fields, rows }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
    rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount)
    fields = try c.decodeIfPresent([SqlField].self, forKey: .fields) ?? []
    rows = try c.decodeIfPresent([AnyJSON].self, forKey: .rows) ?? []
  }

  /// The rows as objects (empty in `arrayMode`).
  public var objects: [JSONObject] { rows.compactMap(\.objectValue) }

  /// The rows decoded as `T`.
  public func decode<T: Decodable>(as: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> [T] {
    try rows.map { try $0.decode(as: T.self, decoder: decoder) }
  }
}

/// One statement with `$1`, `$2`, … parameters.
public struct SqlStatement: Sendable, Equatable {
  public var query: String
  public var params: [AnyJSON]
  /// Rows as arrays of values instead of objects.
  public var arrayMode: Bool?

  public init(_ query: String, _ params: [AnyJSON] = [], arrayMode: Bool? = nil) {
    self.query = query
    self.params = params
    self.arrayMode = arrayMode
  }

  var json: JSONObject {
    var o: JSONObject = ["query": .string(query), "params": .array(params)]
    if let arrayMode { o["arrayMode"] = .bool(arrayMode) }
    return o
  }
}

/// The isolation and access mode of a transaction.
public struct SqlTransactionOptions: Sendable, Equatable {
  public enum Isolation: String, Sendable {
    case readCommitted = "read committed"
    case repeatableRead = "repeatable read"
    case serializable
  }

  public var isolation: Isolation?
  public var readOnly: Bool?
  public var deferrable: Bool?

  public init(isolation: Isolation? = nil, readOnly: Bool? = nil, deferrable: Bool? = nil) {
    self.isolation = isolation
    self.readOnly = readOnly
    self.deferrable = deferrable
  }

  var json: JSONObject {
    var o: JSONObject = [:]
    if let isolation { o["isolation"] = .string(isolation.rawValue) }
    if let readOnly { o["readOnly"] = .bool(readOnly) }
    if let deferrable { o["deferrable"] = .bool(deferrable) }
    return o
  }
}

/// A parameter value: `Date` as ISO 8601, `Data` as `bytea` hex (`\x…`), anything else as JSON.
public func sqlParam(_ value: Date) -> AnyJSON { .string(serviceIsoString(value)) }
public func sqlParam(_ value: Data) -> AnyJSON {
  .string("\\x" + value.map { String(format: "%02x", $0) }.joined())
}

/// Serverless SQL. **Server side only**: the SQL key runs as the project's owner; never ship it in an app.
///
/// ```swift
/// let sql = try StitchSQL(connection: ProcessInfo.processInfo.environment["STITCHDB_SQL_URL"]!)
/// let todos = try await sql.query("select * from todos where owner = $1 limit 20", [.string(userID)])
///
/// // several statements in one transaction, in one request
/// let results = try await sql.transaction([
///   SqlStatement("update stock set left = left - 1 where sku = $1", [.string(sku)]),
///   SqlStatement("insert into orders (sku, buyer) values ($1, $2) returning *", [.string(sku), .string(userID)]),
/// ])
///
/// // interactive transactions over a WebSocket session
/// let db = try await sql.connect()
/// try await db.transaction { tx in
///   let acct = try await tx.query("select balance from accounts where id = $1 for update", [.string(id)])
///   try await tx.query("update accounts set balance = balance - $1 where id = $2", [.integer(amount), .string(id)])
/// }
/// db.close()
/// ```
public final class StitchSQL: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  /// The project URL, `https://<ref>.stitchdb.com`.
  public let url: URL
  let key: String
  let headers: [String: String]
  let fetch: Fetch
  let connectSocket: StitchWebSocketConnect

  /// - Parameters:
  ///   - url: The project URL (or your custom domain).
  ///   - key: A SQL key, `sdb_sql_…`.
  public convenience init(url: URL, key: String, headers: [String: String] = [:], session: URLSession = .shared) {
    self.init(
      url: url, key: key, headers: headers, fetch: { try await session.data(for: $0) },
      connect: stitchWebSocketConnect(session: session)
    )
  }

  /// From the connection URL Studio shows, `https://sdb_sql_…@<ref>.stitchdb.com`.
  public convenience init(connection: String, headers: [String: String] = [:], session: URLSession = .shared) throws {
    let (url, key) = try Self.parse(connection)
    self.init(url: url, key: key, headers: headers, session: session)
  }

  init(
    url: URL, key: String, headers: [String: String], fetch: @escaping Fetch,
    connect: @escaping StitchWebSocketConnect
  ) {
    var base = url.absoluteString
    while base.hasSuffix("/") { base.removeLast() }
    self.url = URL(string: base) ?? url
    self.key = key
    self.headers = headers
    self.fetch = fetch
    self.connectSocket = connect
  }

  static func parse(_ connection: String) throws -> (URL, String) {
    guard let c = URLComponents(string: connection), let scheme = c.scheme, let host = c.host, !host.isEmpty else {
      throw SqlError(message: "The connection URL looks like https://sdb_sql_...@<ref>.stitchdb.com")
    }
    let raw = (c.percentEncodedUser?.isEmpty == false ? c.percentEncodedUser : c.percentEncodedPassword) ?? ""
    let key = raw.removingPercentEncoding ?? raw
    guard !key.isEmpty else {
      throw SqlError(message: "The connection URL has no SQL key (https://sdb_sql_...@<ref>.stitchdb.com)")
    }
    let port = c.port.map { ":\($0)" } ?? ""
    guard let url = URL(string: "\(scheme)://\(host)\(port)") else {
      throw SqlError(message: "The connection URL looks like https://sdb_sql_...@<ref>.stitchdb.com")
    }
    return (url, key)
  }

  private func post(_ body: JSONObject) async throws -> JSONObject {
    var request = URLRequest(url: url.appendingPathComponent("sql/v1/query"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpBody = try JSONEncoder().encode(body)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await fetch(request)
    } catch {
      throw SqlError(message: error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json: JSONObject
    if data.isEmpty {
      json = [:]
    } else if let parsed = try? JSONDecoder().decode(JSONObject.self, from: data) {
      json = parsed
    } else {
      throw SqlError(
        message: "SQL endpoint answered \(status): \(String(decoding: data.prefix(200), as: UTF8.self))", status: status
      )
    }
    guard (200..<300).contains(status) else {
      throw SqlError(json, status: status, fallback: "SQL endpoint answered \(status)")
    }
    return json
  }

  /// Runs one statement with `$1`, `$2`, … parameters and returns the whole result.
  @discardableResult
  public func execute(_ query: String, _ params: [AnyJSON] = [], arrayMode: Bool? = nil) async throws -> SqlResult {
    let json = try await post(SqlStatement(query, params, arrayMode: arrayMode).json)
    return try AnyJSON.object(json).decode(as: SqlResult.self)
  }

  /// Runs one statement and returns its rows as objects.
  @discardableResult
  public func query(_ query: String, _ params: [AnyJSON] = []) async throws -> [JSONObject] {
    try await execute(query, params).objects
  }

  /// Runs one statement and decodes its rows as `T`.
  public func query<T: Decodable>(_ query: String, _ params: [AnyJSON] = [], as: T.Type) async throws -> [T] {
    try await execute(query, params).decode(as: T.self)
  }

  /// Runs the statements in one transaction, in one request: all are committed, or none when one fails (the error's
  /// `index` says which).
  @discardableResult
  public func transaction(_ statements: [SqlStatement], options: SqlTransactionOptions = SqlTransactionOptions())
    async throws -> [SqlResult]
  {
    var body = options.json
    body["transaction"] = .array(statements.map { .object($0.json) })
    let json = try await post(body)
    return try (json["results"] ?? .array([])).decode(as: [SqlResult].self)
  }

  /// Opens a WebSocket session (`wss://<ref>.stitchdb.com/sql/v1/ws`) for interactive transactions.
  public func connect() async throws -> SqlSession {
    var base = url.absoluteString
    if base.hasPrefix("http") { base = "ws" + base.dropFirst(4) }
    guard let wsURL = URL(string: base + "/sql/v1/ws") else { throw SqlError(message: "Invalid URL") }
    let socket: any StitchWebSocketConnection
    do {
      socket = try await connectSocket(wsURL, headers)
    } catch {
      throw SqlError(message: "Could not open the SQL session: \(error.localizedDescription)")
    }
    let session = SqlSession(socket)
    try await session.send(["type": "auth", "key": .string(key)])
    return session
  }
}

/// A WebSocket session. Statements run in the order they are sent; a transaction holds one database connection.
public final class SqlSession: Sendable {
  struct State {
    var pending: [Int: CheckedContinuation<AnyJSON, any Error>] = [:]
    var next = 1
    var closed: SqlError?
    var onNotice: (@Sendable (String) -> Void)?
  }

  private let socket: any StitchWebSocketConnection
  private let state = LockIsolated(State())
  private let reader = LockIsolated<Task<Void, Never>?>(nil)

  init(_ socket: any StitchWebSocketConnection) {
    self.socket = socket
    let task = Task { [weak self, events = socket.events] in
      var code: Int?
      var reason = ""
      for await event in events {
        switch event {
        case .text(let text): self?.message(text)
        case .binary(let data): self?.message(String(decoding: data, as: UTF8.self))
        case .close(let c, let r):
          code = c
          reason = r
        }
      }
      self?.closed(code: code, reason: reason)
    }
    reader.setValue(task)
  }

  deinit {
    reader.value?.cancel()
  }

  /// Called with server notices (for example a transaction rolled back after being idle for 30 s).
  public func onNotice(_ handler: (@Sendable (String) -> Void)?) {
    state.withValue { $0.onNotice = handler }
  }

  private func message(_ text: String) {
    guard let m = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)) else { return }
    if m["type"]?.stringValue == "notice" {
      let handler = state.onNotice
      handler?(m["message"]?.stringValue ?? "")
      return
    }
    guard let id = m["id"]?.intValue,
      let continuation = state.withValue({ $0.pending.removeValue(forKey: id) })
    else { return }
    if let error = m["error"], error != .null {
      continuation.resume(throwing: SqlError(error.objectValue, status: 400, fallback: "Query failed"))
    } else {
      continuation.resume(returning: m["result"] ?? .object(m))
    }
  }

  private func closed(code: Int?, reason: String) {
    let error = SqlError(
      message: "The SQL session closed" + (reason.isEmpty ? "" : ": \(reason)"), status: code ?? 0
    )
    let pending = state.withValue { s -> [CheckedContinuation<AnyJSON, any Error>] in
      if s.closed == nil { s.closed = error }
      defer { s.pending = [:] }
      return Array(s.pending.values)
    }
    for p in pending { p.resume(throwing: error) }
  }

  @discardableResult
  func send(_ message: JSONObject) async throws -> AnyJSON {
    try await withCheckedThrowingContinuation { continuation in
      let id = state.withValue { s -> Int? in
        if s.closed != nil { return nil }
        defer { s.next += 1 }
        s.pending[s.next] = continuation
        return s.next
      }
      guard let id else {
        continuation.resume(throwing: state.closed ?? SqlError(message: "The SQL session closed"))
        return
      }
      var m = message
      m["id"] = .integer(id)
      socket.send(CollabClient.encode(m))
    }
  }

  /// Runs one statement and returns the whole result.
  @discardableResult
  public func execute(_ query: String, _ params: [AnyJSON] = [], arrayMode: Bool? = nil) async throws -> SqlResult {
    var m = SqlStatement(query, params, arrayMode: arrayMode).json
    m["type"] = "query"
    return try await send(m).decode(as: SqlResult.self)
  }

  /// Runs one statement and returns its rows as objects.
  @discardableResult
  public func query(_ query: String, _ params: [AnyJSON] = []) async throws -> [JSONObject] {
    try await execute(query, params).objects
  }

  /// Runs one statement and decodes its rows as `T`.
  public func query<T: Decodable>(_ query: String, _ params: [AnyJSON] = [], as: T.Type) async throws -> [T] {
    try await execute(query, params).decode(as: T.self)
  }

  public func begin(_ options: SqlTransactionOptions = SqlTransactionOptions()) async throws {
    var m = options.json
    m["type"] = "begin"
    try await send(m)
  }

  public func commit() async throws { try await send(["type": "commit"]) }

  public func rollback() async throws { try await send(["type": "rollback"]) }

  /// Runs `body` in a transaction: committed when it returns, rolled back when it throws.
  public func transaction<T: Sendable>(
    _ options: SqlTransactionOptions = SqlTransactionOptions(),
    _ body: (SqlSession) async throws -> T
  ) async throws -> T {
    try await begin(options)
    do {
      let out = try await body(self)
      try await commit()
      return out
    } catch {
      if state.closed == nil { try? await rollback() }
      throw error
    }
  }

  /// Closes the session.
  public func close() {
    if state.closed == nil { socket.close(code: 1000, reason: nil) }
  }
}

import ConcurrencyExtras
public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Offline-first sync (`stitchdb.offline()`): a local copy of the rows the signed-in user may see in the tables that
// sync (Studio › Database › Offline sync). Reads come from the local copy, writes apply locally at once and are
// queued; the queue is pushed and changes are pulled whenever the device is online.
//
// Local layout (the same as the JavaScript SDK): `m` meta (client id, pull cursors, next mutation number), `pk` the
// primary key columns of every synced table, `r/<table>/<pk json>` one row with its server sequence number, and
// `q/<000000000001>` one queued write.

// MARK: - Store

/// Where the local copy lives: `get/set/delete/entries` over string keys with JSON values.
public protocol OfflineStore: Sendable {
  func get(_ key: String) async throws -> AnyJSON?
  func set(_ key: String, _ value: AnyJSON) async throws
  func delete(_ key: String) async throws
  /// Every entry whose key starts with `prefix`, ordered by key.
  func entries(prefix: String) async throws -> [(key: String, value: AnyJSON)]
  /// Removes every entry.
  func clear() async throws
}

/// Keeps the local copy in memory only (lost when the app quits). The default store.
public actor MemoryOfflineStore: OfflineStore {
  private var values: [String: AnyJSON] = [:]

  public init() {}

  public func get(_ key: String) -> AnyJSON? { values[key] }
  public func set(_ key: String, _ value: AnyJSON) { values[key] = value }
  public func delete(_ key: String) { values[key] = nil }
  public func entries(prefix: String) -> [(key: String, value: AnyJSON)] {
    values.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
  }
  public func clear() { values.removeAll() }
}

/// Keeps the local copy on disk: one JSON file per key in `directory` (created when missing), written atomically.
///
/// File names are the base64url form of the key. Use one directory per signed-in user.
public actor FileOfflineStore: OfflineStore {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  private func file(_ key: String) -> URL {
    let name = Data(key.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return directory.appendingPathComponent(name + ".json")
  }

  private static func key(fromFileName name: String) -> String? {
    guard name.hasSuffix(".json") else { return nil }
    var b64 = String(name.dropLast(5))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func read(_ url: URL) -> AnyJSON? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(AnyJSON.self, from: data)
  }

  public func get(_ key: String) -> AnyJSON? { read(file(key)) }

  public func set(_ key: String, _ value: AnyJSON) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: file(key), options: .atomic)
  }

  public func delete(_ key: String) throws {
    let url = file(key)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }

  public func entries(prefix: String) -> [(key: String, value: AnyJSON)] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap { name -> (key: String, value: AnyJSON)? in
      guard let key = Self.key(fromFileName: name), key.hasPrefix(prefix),
        let value = read(directory.appendingPathComponent(name))
      else { return nil }
      return (key: key, value: value)
    }
    .sorted { $0.key < $1.key }
  }

  public func clear() throws {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    where Self.key(fromFileName: name) != nil {
      try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}

// MARK: - Types

/// An error from the sync server or a misuse of the offline client (e.g. a table that does not sync).
public struct OfflineError: Error, LocalizedError, Sendable, Equatable {
  public let message: String
  /// The HTTP status of the failed request, or the status the server would have answered with.
  public let status: Int

  public init(_ message: String, status: Int) {
    self.message = message
    self.status = status
  }

  public var errorDescription: String? { message }
}

/// The state of the offline client.
public struct SyncStatus: Sendable, Equatable {
  public var online: Bool
  public var syncing: Bool
  /// Queued local writes not yet pushed.
  public var pending: Int
  public var lastSyncAt: Date?
  public var error: String?
}

/// Your write lost (`conflict`) or was refused (`rejected`); the local copy now holds the server's row.
public struct ConflictEvent: Sendable, Equatable {
  public enum Status: String, Sendable { case conflict, rejected }
  public let table: String
  public let pk: JSONObject
  public let local: JSONObject?
  public let server: JSONObject?
  public let status: Status
  public let message: String?
}

struct OfflineMutation: Sendable, Equatable {
  var id: String
  var n: Int
  var table: String
  var op: String
  var row: JSONObject?
  var pk: JSONObject?
  var base: Int?
  var at: String

  var target: AnyJSON { row.map(AnyJSON.object) ?? .object(pk ?? [:]) }
  var storeKey: String { "q/" + String(repeating: "0", count: max(0, 12 - String(n).count)) + String(n) }

  /// The shape the server expects.
  var wire: AnyJSON {
    var o: JSONObject = ["id": .string(id), "table": .string(table), "op": .string(op), "at": .string(at)]
    o["base"] = base.map(AnyJSON.integer) ?? .null
    if let row { o["row"] = .object(row) }
    if let pk { o["pk"] = .object(pk) }
    return .object(o)
  }

  var stored: AnyJSON {
    guard case .object(var o) = wire else { return wire }
    o["_n"] = .integer(n)
    return .object(o)
  }

  init(id: String, n: Int, table: String, op: String, row: JSONObject?, pk: JSONObject?, base: Int?, at: String) {
    (self.id, self.n, self.table, self.op, self.row, self.pk, self.base, self.at) = (id, n, table, op, row, pk, base, at)
  }

  init?(_ json: AnyJSON) {
    guard let o = json.objectValue, let id = o["id"]?.stringValue, let table = o["table"]?.stringValue,
      let op = o["op"]?.stringValue
    else { return nil }
    self.init(
      id: id, n: o["_n"].flatMap(intOf) ?? 0, table: table, op: op, row: o["row"]?.objectValue,
      pk: o["pk"]?.objectValue, base: o["base"].flatMap(intOf), at: o["at"]?.stringValue ?? ""
    )
  }
}

private func intOf(_ v: AnyJSON) -> Int? {
  switch v {
  case .integer(let i): i
  case .double(let d): Int(exactly: d.rounded()) ?? nil
  case .string(let s): Int(s)
  default: nil
  }
}

private func stringify(_ v: AnyJSON) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return (try? encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

private func randomID(_ n: Int = 16) -> String {
  let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
  var g = SystemRandomNumberGenerator()
  return String((0..<n).map { _ in chars[Int(UInt8.random(in: .min ... .max, using: &g) & 63)] })
}

private func isoNow() -> String {
  Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Date())
}

// MARK: - Table

/// A synced table in the local copy. Rows are JSON objects that include their primary key columns.
public struct OfflineTable: Sendable {
  public let client: OfflineClient
  public let name: String

  /// Every local row.
  public func all() async -> [JSONObject] { await client.rows(of: name) }

  /// One row by primary key (an object, or the value for a one-column key).
  public func get(_ pk: AnyJSON) async throws -> JSONObject? { try await client.row(of: name, pk: pk) }

  /// Local rows that match.
  public func `where`(_ isIncluded: (JSONObject) throws -> Bool) async rethrows -> [JSONObject] {
    try await all().filter(isIncluded)
  }

  /// Inserts or updates a row locally and queues it for the server. The row must include its primary key.
  public func upsert(_ row: JSONObject) async throws { try await client.write(name, op: "upsert", .object(row)) }

  /// Deletes a row locally and on the server.
  public func delete(_ pk: AnyJSON) async throws { try await client.write(name, op: "delete", pk) }

  /// The table's rows after every local or synced change.
  public func rowUpdates() -> AsyncStream<[JSONObject]> {
    let changes = client.changes()
    let (stream, continuation) = AsyncStream<[JSONObject]>.makeStream()
    let task = Task { [client, name] in
      for await table in changes where table == name {
        continuation.yield(await client.rows(of: name))
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }
}

// MARK: - Client

/// The offline-first sync client. Create one with ``StitchClient/offline(tables:store:interval:batch:)``.
public actor OfflineClient {
  public typealias Fetch = @Sendable (_ request: URLRequest) async throws -> (Data, URLResponse)

  struct Entry: Sendable {
    var row: JSONObject
    var seq: Int
    var json: AnyJSON { .object(["row": .object(row), "seq": .integer(seq)]) }
    init(row: JSONObject, seq: Int) { (self.row, self.seq) = (row, seq) }
    init?(_ v: AnyJSON) {
      guard let o = v.objectValue, let row = o["row"]?.objectValue else { return nil }
      self.init(row: row, seq: o["seq"].flatMap(intOf) ?? 0)
    }
  }

  struct Listeners {
    var change: [UUID: AsyncStream<String>.Continuation] = [:]
    var status: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    var conflict: [UUID: AsyncStream<ConflictEvent>.Continuation] = [:]
  }

  private let url: URL
  private let headers: [String: String]
  private let fetch: Fetch
  private let wantTables: [String]?
  private let interval: TimeInterval
  private let batch: Int
  private let store: any OfflineStore

  private var client = ""
  private var cursors: [String: Int] = [:]
  private var next = 1
  private var pk: [String: [String]] = [:]
  private var data: [String: [String: Entry]] = [:]
  private var queue: [OfflineMutation] = []
  private var timer: Task<Void, Never>?
  private var running: Task<Void, any Error>?
  private var closed = false
  private let opening = LockIsolated<Task<Void, any Error>?>(nil)
  private let listeners = LockIsolated(Listeners())

  /// The current state; also delivered by ``statusUpdates()``.
  public private(set) var status = SyncStatus(online: true, syncing: false, pending: 0, lastSyncAt: nil, error: nil)

  /// - Parameters:
  ///   - url: The sync API, `<project URL>/sync/v1`.
  ///   - headers: Headers for every request (`apikey`, …).
  ///   - fetch: Performs a request (adds the current access token).
  ///   - tables: Tables to keep offline (default: every table that syncs).
  ///   - store: Where the local copy lives (default: memory).
  ///   - interval: Sync every … seconds while online (0 = only when you call ``sync()``).
  ///   - batch: Rows per pull request.
  public init(
    url: URL,
    headers: [String: String],
    fetch: @escaping Fetch,
    tables: [String]? = nil,
    store: (any OfflineStore)? = nil,
    interval: TimeInterval = 30,
    batch: Int = 500
  ) {
    self.url = url
    self.headers = headers
    self.fetch = fetch
    self.wantTables = tables
    self.interval = interval
    self.batch = batch
    self.store = store ?? MemoryOfflineStore()
    opening.withValue { $0 = Task { try await self.open() } }
  }

  /// Returns once the local copy is loaded (it does not wait for the first sync).
  public func ready() async throws {
    try await opening.value?.value
  }

  /// A synced table.
  public nonisolated func table(_ name: String) -> OfflineTable { OfflineTable(client: self, name: name) }

  // MARK: Events

  /// The name of a table after every local or synced change to it.
  public nonisolated func changes() -> AsyncStream<String> {
    let (stream, c) = AsyncStream<String>.makeStream()
    let id = UUID()
    listeners.withValue { $0.change[id] = c }
    c.onTermination = { [listeners] _ in listeners.withValue { _ = $0.change.removeValue(forKey: id) } }
    return stream
  }

  /// Every change of ``status``.
  public nonisolated func statusUpdates() -> AsyncStream<SyncStatus> {
    let (stream, c) = AsyncStream<SyncStatus>.makeStream()
    let id = UUID()
    listeners.withValue { $0.status[id] = c }
    c.onTermination = { [listeners] _ in listeners.withValue { _ = $0.status.removeValue(forKey: id) } }
    return stream
  }

  /// Your write lost or was refused by the server.
  public nonisolated func conflicts() -> AsyncStream<ConflictEvent> {
    let (stream, c) = AsyncStream<ConflictEvent>.makeStream()
    let id = UUID()
    listeners.withValue { $0.conflict[id] = c }
    c.onTermination = { [listeners] _ in listeners.withValue { _ = $0.conflict.removeValue(forKey: id) } }
    return stream
  }

  private func emitChange(_ table: String) {
    for c in listeners.value.change.values { c.yield(table) }
  }

  private func emitConflict(_ e: ConflictEvent) {
    for c in listeners.value.conflict.values { c.yield(e) }
  }

  private func setStatus(_ update: (inout SyncStatus) -> Void) {
    update(&status)
    let s = status
    for c in listeners.value.status.values { c.yield(s) }
  }

  // MARK: Requests

  private func req(_ path: String, _ body: AnyJSON? = nil) async throws -> JSONObject {
    var request = URLRequest(url: url.appendingPathComponent(path))
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let (data, response) = try await fetch(request)
    let json = (try? JSONDecoder().decode(AnyJSON.self, from: data))?.objectValue ?? [:]
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
      throw OfflineError(json["message"]?.stringValue ?? "Sync failed (\(code))", status: code)
    }
    return json
  }

  // MARK: Open

  private var metaJSON: AnyJSON {
    .object([
      "client": .string(client), "cursors": .object(cursors.mapValues(AnyJSON.integer)), "next": .integer(next),
    ])
  }

  private func open() async throws {
    if let m = try await store.get("m")?.objectValue {
      client = m["client"]?.stringValue ?? ""
      cursors = (m["cursors"]?.objectValue ?? [:]).compactMapValues(intOf)
      next = m["next"].flatMap(intOf) ?? 1
    }
    if client.isEmpty {
      client = randomID()
      try await store.set("m", metaJSON)
    }
    pk = (try await store.get("pk")?.objectValue ?? [:]).compactMapValues { $0.arrayValue?.compactMap(\.stringValue) }
    for (k, v) in try await store.entries(prefix: "r/") {
      let rest = k.dropFirst(2)
      guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex, let entry = Entry(v) else { continue }
      data[String(rest[..<slash]), default: [:]][String(rest[rest.index(after: slash)...])] = entry
    }
    queue = try await store.entries(prefix: "q/").compactMap { OfflineMutation($0.value) }.sorted { $0.n < $1.n }
    status.pending = queue.count
    do {
      try await loadTables()
    } catch {
      if pk.isEmpty { setStatus { $0.online = false; $0.error = error.localizedDescription } }
    }
    if interval > 0 {
      let nanos = UInt64(interval * 1_000_000_000)
      timer = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: nanos)
          guard let self, !Task.isCancelled else { return }
          await self.tick()
        }
      }
    }
    _ = startSync()
  }

  private func tick() {
    if status.online { _ = startSync() }
  }

  private func loadTables() async throws {
    let list = try await req("tables")["tables"]?.arrayValue ?? []
    var found: [String: [String]] = [:]
    for t in list {
      guard let o = t.objectValue, let name = o["name"]?.stringValue else { continue }
      if wantTables == nil || wantTables!.contains(name) {
        found[name] = o["pk"]?.arrayValue?.compactMap(\.stringValue) ?? []
      }
    }
    for name in wantTables ?? [] where found[name] == nil {
      throw OfflineError("\(name) does not sync. Turn it on in Studio › Database › Offline sync.", status: 404)
    }
    pk = found
    try await store.set("pk", .object(found.mapValues { .array($0.map(AnyJSON.string)) }))
  }

  // MARK: Local data

  func rows(of table: String) -> [JSONObject] {
    (data[table] ?? [:]).values.map(\.row)
  }

  func row(of table: String, pk value: AnyJSON) throws -> JSONObject? {
    data[table]?[try key(table, value)]?.row
  }

  private func key(_ table: String, _ v: AnyJSON) throws -> String {
    guard let cols = pk[table], let first = cols.first else {
      throw OfflineError("\(table) is not synced offline", status: 404)
    }
    let o = v.objectValue ?? [first: v]
    let values = try cols.map { c -> AnyJSON in
      guard let x = o[c], !x.isNil else {
        throw OfflineError("\(table): the primary key column \(c) is missing", status: 400)
      }
      return x
    }
    return stringify(.array(values))
  }

  private func pkObject(_ table: String, _ v: AnyJSON) -> JSONObject {
    let cols = pk[table] ?? []
    let o = v.objectValue ?? (cols.first.map { [$0: v] } ?? [:])
    var out: JSONObject = [:]
    for c in cols { out[c] = o[c] ?? .null }
    return out
  }

  private func put(_ table: String, _ key: String, _ entry: Entry?) async throws {
    if let entry {
      data[table, default: [:]][key] = entry
      try await store.set("r/\(table)/\(key)", entry.json)
    } else {
      data[table]?[key] = nil
      try await store.delete("r/\(table)/\(key)")
    }
  }

  func write(_ table: String, op: String, _ v: AnyJSON) async throws {
    try await ready()
    let key = try key(table, v)
    let cur = data[table]?[key]
    let id = "\(client).\(next)"
    next += 1
    var row: JSONObject?
    if op == "upsert" { row = (cur?.row ?? [:]).merging(v.objectValue ?? [:]) { _, new in new } }
    let m = OfflineMutation(
      id: id, n: next, table: table, op: op, row: row, pk: op == "upsert" ? nil : pkObject(table, v),
      base: cur?.seq, at: isoNow()
    )
    if let row {
      let entry = Entry(row: row, seq: cur?.seq ?? 0)
      data[table, default: [:]][key] = entry
      try await store.set("r/\(table)/\(key)", entry.json)
    } else {
      data[table]?[key] = nil
      try await store.delete("r/\(table)/\(key)")
    }
    queue.append(m)
    try await store.set(m.storeKey, m.stored)
    try await store.set("m", metaJSON)
    setStatus { $0.pending = queue.count }
    emitChange(table)
    if status.online { _ = startSync() }
  }

  // MARK: Sync

  /// Pushes queued writes, then pulls until up to date. Throws if the server can't be reached.
  public func sync() async throws {
    try await startSync().value
  }

  private func startSync() -> Task<Void, any Error> {
    if closed { return Task<Void, any Error> {} }
    if let running {
      return Task {
        try await running.value
        if self.hasQueue { try await self.sync() }
      }
    }
    let task = Task {
      do {
        try await self.run()
      } catch {
        self.finishRun()
        throw error
      }
      self.finishRun()
    }
    running = task
    return task
  }

  private var hasQueue: Bool { !queue.isEmpty }
  private func finishRun() { running = nil }

  private func run() async throws {
    try? await ready()
    setStatus { $0.syncing = true }
    do {
      if pk.isEmpty { try await loadTables() }
      try await pushAll()
      try await pullAll()
      setStatus {
        $0.online = true
        $0.syncing = false
        $0.error = nil
        $0.lastSyncAt = Date()
      }
    } catch {
      setStatus {
        $0.syncing = false
        $0.online = !(error is URLError)
        $0.error = error.localizedDescription
      }
      throw error
    }
  }

  private func pushAll() async throws {
    while !queue.isEmpty {
      let batch = Array(queue.prefix(200))
      let res = try await req(
        "push", .object(["client": .string(client), "mutations": .array(batch.map(\.wire))])
      )
      for (i, result) in (res["results"]?.arrayValue ?? []).enumerated() where i < batch.count {
        let m = batch[i]
        let r = result.objectValue ?? [:]
        let key = try key(m.table, m.target)
        let later = queue.contains { q in
          q.id != m.id && q.table == m.table && (try? self.key(q.table, q.target)) == key
        }
        let status = r["status"]?.stringValue
        if let s = status.flatMap(ConflictEvent.Status.init(rawValue:)) {
          emitConflict(
            ConflictEvent(
              table: m.table, pk: r["pk"]?.objectValue ?? pkObject(m.table, m.target), local: m.row,
              server: r["row"]?.objectValue, status: s, message: r["message"]?.stringValue
            )
          )
        }
        let seq = r["seq"].flatMap(intOf)
        if !later {
          try await put(m.table, key, r["row"]?.objectValue.map { Entry(row: $0, seq: seq ?? 0) })
        } else if let seq, seq != 0 {
          for j in queue.indices
          where queue[j].id != m.id && queue[j].table == m.table && (try? self.key(queue[j].table, queue[j].target)) == key {
            queue[j].base = seq
          }
        }
        queue.removeAll { $0.id == m.id }
        try await store.delete(m.storeKey)
        emitChange(m.table)
      }
      setStatus { $0.pending = queue.count }
    }
  }

  private func pullAll() async throws {
    var more = true
    while more {
      let tables = JSONObject(uniqueKeysWithValues: pk.keys.map { ($0, AnyJSON.integer(cursors[$0] ?? 0)) })
      let r = try await req("pull", .object(["tables": .object(tables), "limit": .integer(batch)]))
      let reset = (r["reset"]?.arrayValue ?? []).compactMap(\.stringValue)
      for t in reset {
        for k in Array((data[t] ?? [:]).keys) { try await put(t, k, nil) }
        cursors[t] = 0
      }
      for (t, list) in r["changes"]?.objectValue ?? [:] {
        let changes = list.arrayValue ?? []
        let pending = Set(queue.filter { $0.table == t }.compactMap { try? key(t, $0.target) })
        for change in changes {
          guard let ch = change.objectValue else { continue }
          let key = try key(t, ch["pk"] ?? .null)
          if pending.contains(key) { continue }  // the local write wins until it is pushed
          try await put(
            t, key,
            ch["op"]?.stringValue == "u"
              ? Entry(row: ch["row"]?.objectValue ?? [:], seq: ch["seq"].flatMap(intOf) ?? 0) : nil
          )
        }
        if !changes.isEmpty || reset.contains(t) { emitChange(t) }
      }
      for (t, v) in r["cursors"]?.objectValue ?? [:] { if let c = intOf(v) { cursors[t] = c } }
      try await store.set("m", metaJSON)
      more = r["more"]?.boolValue ?? false
    }
  }

  // MARK: Close

  /// Stops syncing. With `clear: true` also deletes the local copy and the queued writes (e.g. on sign-out).
  /// Finishes every event stream.
  public func close(clear: Bool = false) async throws {
    closed = true
    timer?.cancel()
    timer = nil
    _ = await running?.result
    if clear { try await store.clear() }
    let l = listeners.withValue { l -> Listeners in
      defer { l = Listeners() }
      return l
    }
    l.change.values.forEach { $0.finish() }
    l.status.values.forEach { $0.finish() }
    l.conflict.values.forEach { $0.finish() }
  }
}

// MARK: - StitchClient

extension StitchClient {
  /// Offline-first sync: a local copy of the rows the signed-in user may see in the tables that sync
  /// (Studio › Database › Offline sync). Reads are local; writes apply locally at once and are pushed when online.
  ///
  /// ```swift
  /// let offline = stitchdb.offline(tables: ["todos"], store: FileOfflineStore(directory: dir))
  /// try await offline.ready()
  /// try await offline.table("todos").upsert(["id": .string(UUID().uuidString), "title": "Milk"])
  /// for await rows in offline.table("todos").rowUpdates() { render(rows) }
  /// ```
  /// - Parameters:
  ///   - tables: Tables to keep offline (default: every table that syncs).
  ///   - store: Where the local copy lives (default: memory). Use one per signed-in user.
  ///   - interval: Sync every … seconds while online (default 30; 0 = only when you call `sync()`).
  ///   - batch: Rows per pull request (default 500).
  public func offline(
    tables: [String]? = nil,
    store: (any OfflineStore)? = nil,
    interval: TimeInterval = 30,
    batch: Int = 500
  ) -> OfflineClient {
    OfflineClient(
      url: stitchURL.appendingPathComponent("/sync/v1"),
      headers: headers,
      fetch: fetchWithAuth,
      tables: tables,
      store: store,
      interval: interval,
      batch: batch
    )
  }
}

import ConcurrencyExtras
import Foundation
import HTTPTypes
import Helpers
import Testing

@testable import RealtimeV2
@testable import StitchDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A WebSocket fake: records what is sent, `reply` answers sent messages, `receive` pushes server messages.
final class FakeSocket: StitchWebSocketConnection {
  let sent = LockIsolated<[JSONObject]>([])
  let closed = LockIsolated(false)
  let events: AsyncStream<StitchWebSocketEvent>
  private let continuation: AsyncStream<StitchWebSocketEvent>.Continuation
  let reply: @Sendable (JSONObject) -> JSONObject?

  init(reply: @escaping @Sendable (JSONObject) -> JSONObject? = { _ in nil }) {
    (events, continuation) = AsyncStream.makeStream()
    self.reply = reply
  }

  func send(_ text: String) {
    guard let m = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)) else { return }
    sent.withValue { $0.append(m) }
    if let answer = reply(m) { receive(answer) }
  }

  func close(code: Int?, reason: String?) {
    closed.setValue(true)
    continuation.yield(.close(code: code, reason: reason ?? ""))
    continuation.finish()
  }

  func receive(_ message: JSONObject) {
    continuation.yield(.text(CollabClient.encode(message)))
  }

  func sent(_ type: String, key: String = "t") -> [JSONObject] {
    sent.value.filter { $0[key]?.stringValue == type }
  }
}

func eventually(_ timeout: Double = 3, _ condition: @Sendable () -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(timeout)
  while Date() < end {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  return condition()
}

/// A Yjs stand-in: updates are opaque bytes; the document is the list of updates applied.
final class FakeYDoc: CollabDocument {
  let applied = LockIsolated<[Data]>([])
  let handlers = LockIsolated<[Int: @Sendable (Data) -> Void]>([:])

  func applyUpdate(_ update: Data) {
    applied.withValue { $0.append(update) }
    // Yjs reports remote updates too; the room must not send these back
    for h in handlers.value.values { h(update) }
  }

  func encodeStateAsUpdate() -> Data { Data(applied.value.joined()) }

  func observeUpdates(_ handler: @escaping @Sendable (Data) -> Void) -> @Sendable () -> Void {
    let key = handlers.withValue { h -> Int in
      let k = h.count + 1
      h[k] = handler
      return k
    }
    return { [handlers] in handlers.withValue { _ = $0.removeValue(forKey: key) } }
  }

  /// A local edit.
  func edit(_ update: Data) {
    applied.withValue { $0.append(update) }
    for h in handlers.value.values { h(update) }
  }
}

struct FakeYjs: CollabYjs {
  func mergeUpdates(_ updates: [Data]) -> Data { Data(updates.joined()) }
  func makeDocument() -> any CollabDocument { FakeYDoc() }
}

/// An HTTP client stand-in for the Realtime history.
final class FakeHTTP: HTTPClientType {
  let requests = LockIsolated<[Helpers.HTTPRequest]>([])
  let answer: @Sendable (Helpers.HTTPRequest) -> (Int, JSONObject)

  init(_ answer: @escaping @Sendable (Helpers.HTTPRequest) -> (Int, JSONObject)) { self.answer = answer }

  func send(_ request: Helpers.HTTPRequest) async throws -> Helpers.HTTPResponse {
    requests.withValue { $0.append(request) }
    let (status, json) = answer(request)
    let response = HTTPURLResponse(url: request.url, statusCode: status, httpVersion: nil, headerFields: nil)!
    return Helpers.HTTPResponse(data: try JSONEncoder().encode(json), response: response)
  }
}

@Suite(.serialized)
struct SocketTests {
  // MARK: Collab

  @Test
  func collabJoinsSyncsAndSendsLocalEdits() async throws {
    let socket = FakeSocket()
    let connectedURL = LockIsolated<URL?>(nil)
    let http = ServiceHTTP(url: URL(string: "https://ref.stitchdb.com/collab/v1")!, headers: [:])
    let collab = CollabClient(
      wsURL: URL(string: "wss://ref.stitchdb.com/collab/v1/ws")!, http: http, apikey: "anon-key",
      getToken: { "user-jwt" },
      connect: { url, _ in
        connectedURL.setValue(url)
        return socket
      },
      yjs: FakeYjs()
    )
    let doc = FakeYDoc()
    let opening = Task { try await collab.open("plan", document: doc, create: true, title: "Plan") }

    #expect(await eventually { !socket.sent("auth").isEmpty })
    #expect(socket.sent("auth").first?["apikey"] == "anon-key")
    #expect(socket.sent("auth").first?["token"] == "user-jwt")
    socket.receive(["t": "ready", "client": "c1"])
    #expect(await eventually { !socket.sent("join").isEmpty })
    let join = try #require(socket.sent("join").first)
    #expect(join["doc"] == "plan")
    #expect(join["create"]?.objectValue?["title"] == "Plan")

    socket.receive([
      "t": "joined", "doc": "plan", "write": true, "seq": 3, "count": 1, "size": 2,
      "updates": [.string(Data("u1".utf8).base64EncodedString())],
      "peers": [["client": "c2", "state": ["name": "Bo"]]],
    ])
    let room = try await opening.value
    #expect(connectedURL.value?.absoluteString == "wss://ref.stitchdb.com/collab/v1/ws")
    #expect(room.isSynced)
    #expect(room.canWrite)
    #expect(doc.applied.value == [Data("u1".utf8)])
    #expect(room.peers["c2"]?["name"] == "Bo")
    #expect(socket.sent("update").isEmpty)  // the stored update is not sent back

    doc.edit(Data("e1".utf8))
    #expect(await eventually { socket.sent("update").count == 1 })
    let update = try #require(socket.sent("update").first)
    #expect(update["data"]?.stringValue == Data("e1".utf8).base64EncodedString())
    #expect(room.unsaved == 1)
    socket.receive(["t": "ack", "doc": "plan", "id": update["id"] ?? .null, "seq": 4])
    #expect(await eventually { room.unsaved == 0 })

    socket.receive(["t": "update", "doc": "plan", "data": .string(Data("r1".utf8).base64EncodedString()), "seq": 5, "client": "c2"])
    #expect(await eventually { doc.applied.value.count == 3 })
    #expect(socket.sent("update").count == 1)

    let seen = LockIsolated<[String: JSONObject]>([:])
    let token = room.onPresence { peers in seen.setValue(peers) }
    socket.receive(["t": "presence", "doc": "plan", "client": "c3", "state": ["name": "Cy"]])
    #expect(await eventually { seen.value["c3"]?["name"] == "Cy" })
    room.setPresence(["name": "Me"])
    #expect(socket.sent("presence").last?["state"]?.objectValue?["name"] == "Me")
    token.cancel()

    room.close()
    #expect(socket.sent("leave").first?["doc"] == "plan")
    collab.close()
    #expect(socket.closed.value)
  }

  @Test
  func collabOpenFailsOnError() async throws {
    let socket = FakeSocket { m in
      if m["t"] == "auth" { return ["t": "ready", "client": "c1"] }
      if m["t"] == "join" { return ["t": "error", "doc": "secret", "code": "forbidden", "message": "No access"] }
      return nil
    }
    let collab = CollabClient(
      wsURL: URL(string: "wss://ref.stitchdb.com/collab/v1/ws")!,
      http: ServiceHTTP(url: URL(string: "https://ref.stitchdb.com/collab/v1")!, headers: [:]), apikey: "anon-key",
      getToken: { nil }, connect: { _, _ in socket }, yjs: FakeYjs()
    )
    do {
      _ = try await collab.open("secret", document: FakeYDoc())
      Issue.record("expected an error")
    } catch let error as CollabError {
      #expect(error.code == "forbidden")
      #expect(error.message == "No access")
    }
    collab.close()
  }

  @Test
  func collabHTTPErrorsMapToCodes() {
    #expect(CollabError(message: "x", status: 403, code: nil).code == "forbidden")
    #expect(CollabError(message: "x", status: 404, code: nil).code == "not_found")
    #expect(CollabError(message: "x", status: 500, code: nil).code == "http_500")
  }

  // MARK: SQL

  @Test
  func sqlParsesTheConnectionURL() throws {
    let (url, key) = try StitchSQL.parse("https://sdb_sql_abc123@ref.stitchdb.com")
    #expect(url.absoluteString == "https://ref.stitchdb.com")
    #expect(key == "sdb_sql_abc123")
    #expect(throws: SqlError.self) { _ = try StitchSQL.parse("https://ref.stitchdb.com") }
  }

  @Test
  func sqlQueryAndTransactionOverHTTP() async throws {
    let requests = LockIsolated<[URLRequest]>([])
    let sql = StitchSQL(
      url: URL(string: "https://ref.stitchdb.com/")!, key: "sdb_sql_k", headers: [:],
      fetch: { request in
        requests.withValue { $0.append(request) }
        let body = try JSONDecoder().decode(JSONObject.self, from: request.httpBody ?? Data())
        let answer: JSONObject
        var status = 200
        if body["transaction"] != nil {
          answer = [
            "results": [
              ["command": "UPDATE", "rowCount": 1, "fields": [], "rows": []],
              ["command": "INSERT", "rowCount": 1, "fields": [["name": "id", "dataTypeID": 23]], "rows": [["id": 9]]],
            ]
          ]
        } else if body["query"] == "bad" {
          status = 400
          answer = ["message": "syntax error at or near \"bad\"", "code": "42601", "position": "1"]
        } else {
          answer = [
            "command": "SELECT", "rowCount": 1, "fields": [["name": "n", "dataTypeID": 23]], "rows": [["n": 1]],
          ]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONEncoder().encode(answer), response)
      },
      connect: { _, _ in FakeSocket() }
    )
    let rows = try await sql.query("select $1::int as n", [1])
    #expect(rows == [["n": 1]])
    let first = try #require(requests.value.first)
    #expect(first.url?.absoluteString == "https://ref.stitchdb.com/sql/v1/query")
    #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer sdb_sql_k")
    let body = try JSONDecoder().decode(JSONObject.self, from: first.httpBody ?? Data())
    #expect(body["params"] == [1])

    let results = try await sql.transaction(
      [SqlStatement("update stock set left = left - 1"), SqlStatement("insert into orders default values returning id")],
      options: SqlTransactionOptions(isolation: .serializable)
    )
    #expect(results.map(\.command) == ["UPDATE", "INSERT"])
    let txBody = try JSONDecoder().decode(JSONObject.self, from: requests.value.last?.httpBody ?? Data())
    #expect(txBody["isolation"] == "serializable")
    #expect(txBody["transaction"]?.arrayValue?.count == 2)

    do {
      try await sql.execute("bad")
      Issue.record("expected an error")
    } catch let error as SqlError {
      #expect(error.code == "42601")
      #expect(error.status == 400)
      #expect(error.position == "1")
    }
  }

  @Test
  func sqlSessionTransaction() async throws {
    let socket = FakeSocket { m in
      guard let id = m["id"] else { return nil }
      switch m["type"]?.stringValue {
      case "query":
        if m["query"] == "fail" { return ["id": id, "error": ["message": "boom", "code": "P0001"]] }
        return ["id": id, "result": ["command": "SELECT", "rowCount": 1, "fields": [], "rows": [["balance": 10]]]]
      default: return ["id": id, "result": [:]]
      }
    }
    let wsURL = LockIsolated<URL?>(nil)
    let sql = StitchSQL(
      url: URL(string: "https://ref.stitchdb.com")!, key: "sdb_sql_k", headers: [:],
      fetch: { _ in throw URLError(.notConnectedToInternet) },
      connect: { url, _ in
        wsURL.setValue(url)
        return socket
      }
    )
    let db = try await sql.connect()
    #expect(wsURL.value?.absoluteString == "wss://ref.stitchdb.com/sql/v1/ws")
    #expect(socket.sent("auth", key: "type").first?["key"] == "sdb_sql_k")
    let balance = try await db.transaction { tx in
      try await tx.query("select balance from accounts").first?["balance"]?.intValue
    }
    #expect(balance == 10)
    #expect(socket.sent.value.compactMap { $0["type"]?.stringValue } == ["auth", "begin", "query", "commit"])

    await #expect(throws: SqlError.self) {
      try await db.transaction { tx in try await tx.query("fail") }
    }
    #expect(socket.sent.value.last?["type"] == "rollback")
    db.close()
    #expect(socket.closed.value)
  }

  // MARK: Realtime history

  @Test
  func historyCatchesUpDedupesAndPublishes() async throws {
    let http = FakeHTTP { request in
      if request.method == .post { return (201, ["id": "m9", "inserted_at": "2026-11-02T00:00:00Z"]) }
      return (
        200,
        [
          "messages": [
            ["id": "m1", "event": "chat", "payload": ["t": "old"]],
            ["id": "m2", "event": "chat", "payload": ["t": "missed"]],
          ],
          "more": false,
        ]
      )
    }
    let delivered = LockIsolated<[(String, JSONObject)]>([])
    let history = RealtimeHistory(
      topic: "room:1", isPrivate: true, url: URL(string: "https://ref.p.stitchdb.com/history/v1")!,
      config: RealtimeHistoryConfig(), http: http,
      headers: { [.authorization: "Bearer jwt"] },
      deliver: { event, payload in delivered.withValue { $0.append((event, payload)) } }
    )
    // no position yet: nothing to catch up
    await history.catchUp()
    #expect(http.requests.value.isEmpty)

    history.live(event: "chat", payload: ["type": "broadcast", "event": "chat", "payload": ["t": "live"], "meta": ["id": "m1"]])
    history.live(event: "chat", payload: ["type": "broadcast", "event": "chat", "payload": ["t": "live"], "meta": ["id": "m1"]])
    #expect(delivered.value.count == 1)

    await history.catchUp()
    let get = try #require(http.requests.value.first)
    #expect(get.url.absoluteString == "https://ref.p.stitchdb.com/history/v1/messages")
    let q = Dictionary(get.query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    #expect(q["topic"] == "room:1")
    #expect(q["private"] == "true")
    #expect(q["after"] == "m1")
    #expect(get.headers[.authorization] == "Bearer jwt")
    #expect(delivered.value.count == 2)
    let replay = try #require(delivered.value.last?.1)
    #expect(replay["payload"]?.objectValue?["t"] == "missed")
    #expect(replay["meta"]?.objectValue?["replayed"] == true)

    history.live(event: "chat", payload: ["type": "broadcast", "event": "chat", "meta": ["id": "m2"]])
    #expect(delivered.value.count == 2)

    let stored = try await history.publish(event: "chat", payload: ["t": "hi"])
    #expect(stored.id == "m9")
    let post = try #require(http.requests.value.last)
    let body = try JSONDecoder().decode(JSONObject.self, from: post.body ?? Data())
    #expect(body["topic"] == "room:1")
    #expect(body["private"] == true)
    #expect(body["payload"]?.objectValue?["t"] == "hi")
  }

  @Test
  func historyStartsFromSince() async throws {
    let http = FakeHTTP { _ in (200, ["messages": [], "more": false]) }
    let history = RealtimeHistory(
      topic: "t", isPrivate: false, url: URL(string: "https://ref.p.stitchdb.com/history/v1")!,
      config: RealtimeHistoryConfig(since: Date(timeIntervalSince1970: 1_700_000_000)), http: http,
      headers: { [:] }, deliver: { _, _ in }
    )
    await history.catchUp()
    let q = Dictionary(
      (http.requests.value.first?.query ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 }
    )
    #expect(q["since"] == "1700000000000")
    #expect(q["private"] == "false")
  }

  @Test
  func historyURLIsNextToRealtime() {
    let client = makePlatformClient(URL(string: "https://histref.stitchdb.com")!)
    #expect(client.realtimeV2.historyURL?.absoluteString == "https://histref.stitchdb.com/history/v1")
    let channel = client.channel("room") { $0.history = RealtimeHistoryConfig() }
    #expect(channel.history?.enabled == true)
    #expect(client.channel("other").history?.enabled == false)
  }
}

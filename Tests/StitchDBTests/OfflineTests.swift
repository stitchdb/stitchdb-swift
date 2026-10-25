import ConcurrencyExtras
import Foundation
import Testing

@testable import StitchDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A fake sync server: `up` toggles whether it answers, every pushed mutation is recorded.
final class OfflineSyncProtocol: URLProtocol {
  static let up = LockIsolated(false)
  static let pushed = LockIsolated<[JSONObject]>([])
  static let requests = LockIsolated<[URLRequest]>([])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let n = stream.read(&buffer, maxLength: buffer.count)
      if n <= 0 { break }
      data.append(buffer, count: n)
    }
    return data
  }

  private static func respond(_ request: URLRequest) -> (Int, AnyJSON) {
    requests.withValue { $0.append(request) }
    guard up.value else { return (503, ["message": "down"]) }
    let path = request.url?.path ?? ""
    if path.hasSuffix("/sync/v1/tables") {
      return (200, ["tables": [["name": "todos", "pk": ["id"], "conflict": "last_write_wins"]]])
    }
    if path.hasSuffix("/sync/v1/push") {
      let b = (try? JSONDecoder().decode(AnyJSON.self, from: body(of: request)))?.objectValue ?? [:]
      let mutations = (b["mutations"]?.arrayValue ?? []).compactMap(\.objectValue)
      pushed.withValue { $0.append(contentsOf: mutations) }
      let results: [AnyJSON] = mutations.map { m in
        let row = m["row"] ?? .null
        return [
          "id": m["id"] ?? .null, "status": "applied", "seq": 7,
          "pk": ["id": row.objectValue?["id"] ?? .null], "row": row,
        ]
      }
      return (200, ["results": .array(results)])
    }
    if path.hasSuffix("/sync/v1/pull") {
      return (
        200,
        [
          "changes": ["todos": [["seq": 8, "op": "u", "pk": ["id": "b"], "row": ["id": "b", "title": "from server"]]]],
          "cursors": ["todos": 8], "more": false, "reset": [],
        ]
      )
    }
    return (404, ["message": "not found"])
  }

  override func startLoading() {
    let (code, json) = Self.respond(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(json)) ?? Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite
struct OfflineTests {
  @Test
  func writesQueueWhileTheServerIsDownAndSurviveARestart() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfflineSyncProtocol.self]
    let c = StitchClient(
      stitchURL: URL(string: "https://abcdefghijklmnop.stitchdb.com")!,
      stitchKey: "anon-key",
      options: StitchClientOptions(
        auth: StitchClientOptions.AuthOptions(storage: AuthLocalStorageMock(), autoRefreshToken: false),
        global: StitchClientOptions.GlobalOptions(session: URLSession(configuration: config))
      )
    )
    let store = MemoryOfflineStore()

    OfflineSyncProtocol.up.setValue(true)
    var off = c.offline(store: store, interval: 0)
    try await off.ready()
    try? await off.sync()
    OfflineSyncProtocol.up.setValue(false)
    try await off.table("todos").upsert(["id": "a", "title": "offline"])
    #expect(await off.status.pending == 1)
    try await off.close()

    off = c.offline(store: store, interval: 0)
    try await off.ready()
    try? await off.sync()  // still down
    #expect(await off.status.pending == 1, "queue persisted")
    #expect(try await off.table("todos").get("a")?["title"] == "offline")

    OfflineSyncProtocol.up.setValue(true)
    try await off.sync()
    #expect(await off.status.pending == 0)
    let pushed = OfflineSyncProtocol.pushed.value
    #expect(pushed.map { [$0["table"], $0["op"], $0["row"]?.objectValue?["title"], $0["base"]] } == [["todos", "upsert", "offline", .null]])
    let id = pushed.first?["id"]?.stringValue ?? ""
    let parts = id.split(separator: ".")
    #expect(parts.count == 2 && parts[0].count == 16 && Int(parts[1]) != nil, "\(id)")
    #expect(parts.first?.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } == true)
    #expect(try await off.table("todos").get("b")?["title"] == "from server")

    for r in OfflineSyncProtocol.requests.value {
      #expect(r.url?.absoluteString.hasPrefix("https://abcdefghijklmnop.stitchdb.com/sync/v1/") == true)
      #expect(r.value(forHTTPHeaderField: "apikey") == "anon-key")
      #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer anon-key")
    }
    try await off.close(clear: true)
    #expect(await store.entries(prefix: "").isEmpty)
  }

  @Test
  func fileStoreKeepsEntriesAcrossInstances() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = FileOfflineStore(directory: dir)
    try await a.set("r/todos/[\"a/b\"]", ["row": ["id": "a/b"], "seq": 3])
    try await a.set("q/000000000002", ["id": "x.1"])
    try await a.set("m", ["next": 2])
    let b = FileOfflineStore(directory: dir)
    #expect(await b.get("m") == ["next": 2])
    #expect(await b.entries(prefix: "r/").map(\.key) == ["r/todos/[\"a/b\"]"])
    try await b.delete("q/000000000002")
    #expect(await b.entries(prefix: "q/").isEmpty)
    try await b.clear()
    #expect(await b.entries(prefix: "").isEmpty)
    #expect(await b.get("m") == nil)
  }
}

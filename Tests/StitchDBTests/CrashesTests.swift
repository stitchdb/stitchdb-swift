import ConcurrencyExtras
import Foundation
import Testing

@testable import StitchDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A fake crash reporting server: `reportStatus` is the answer to `/crashes/v1/report`, every request is recorded.
final class CrashServerProtocol: URLProtocol {
  static let reportStatus = LockIsolated(200)
  static let requests = LockIsolated<[(request: URLRequest, body: AnyJSON)]>([])

  static func reset() {
    reportStatus.setValue(200)
    requests.setValue([])
  }

  static func bodies(_ suffix: String) -> [JSONObject] {
    requests.value.filter { $0.request.url?.path.hasSuffix(suffix) == true }.compactMap(\.body.objectValue)
  }

  static func reports() -> [JSONObject] {
    bodies("/crashes/v1/report").flatMap { ($0["reports"]?.arrayValue ?? []).compactMap(\.objectValue) }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  static func body(of request: URLRequest) -> Data {
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
    let json = (try? JSONDecoder().decode(AnyJSON.self, from: body(of: request))) ?? .null
    requests.withValue { $0.append((request, json)) }
    let path = request.url?.path ?? ""
    if path.hasSuffix("/crashes/v1/report") {
      let status = reportStatus.value
      return (status, status == 200 ? ["received": 1, "stored": 1, "dropped": 0, "issues": []] : ["message": "no"])
    }
    if path.hasSuffix("/crashes/v1/session") { return (200, ["ok": true]) }
    if path.hasSuffix("/rest/v1/orders") { return (500, ["code": "XX000", "message": "boom"]) }
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

struct CheckoutFailed: Error, CustomStringConvertible {
  var description: String { "card declined" }
}

private func makeCrashClient() -> StitchClient {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [CrashServerProtocol.self]
  return StitchClient(
    stitchURL: URL(string: "https://abcdefghijklmnop.stitchdb.com")!,
    stitchKey: "anon-key",
    options: StitchClientOptions(
      auth: StitchClientOptions.AuthOptions(storage: AuthLocalStorageMock(), autoRefreshToken: false),
      global: StitchClientOptions.GlobalOptions(session: URLSession(configuration: config))
    )
  )
}

private func tempDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("crashes-\(UUID().uuidString)")
}

@Suite(.serialized)
struct CrashesTests {
  @Test
  func reportIsSentWithAnAPIBreadcrumbWithoutQueryValues() async throws {
    CrashServerProtocol.reset()
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeCrashClient()

    c.crashes.captureError(CheckoutFailed())  // before start: nothing
    c.crashes.start(release: "1.4.0", captureUnhandled: false, directory: dir)
    _ = try? await c.from("orders").select("id").eq("id", value: 5).execute()
    c.crashes.addBreadcrumb(type: "ui", message: "tapped Checkout")
    c.crashes.captureError(CheckoutFailed(), context: ["step": "payment"], fingerprint: ["checkout"])
    await c.crashes.flush()

    let reports = CrashServerProtocol.reports()
    #expect(reports.count == 1)
    let r = try #require(reports.first)
    #expect(r["platform"] == "swift")
    #expect(r["release"] == "1.4.0")
    #expect(r["environment"] == "production")
    #expect(r["handled"] == true)
    #expect(r["context"] == ["step": "payment"])
    #expect(r["fingerprint"] == ["checkout"])
    #expect(r["install_id"]?.stringValue?.isEmpty == false)
    let ex = try #require(r["exception"]?.objectValue)
    #expect(ex["type"]?.stringValue?.hasSuffix("CheckoutFailed") == true)
    #expect(ex["message"] == "card declined")
    #expect(ex["stack"]?.stringValue?.isEmpty == false)
    let device = try #require(r["device"]?.objectValue)
    #expect(device["sdk"]?.stringValue?.hasPrefix("stitchdb-swift/") == true)
    #expect(device["os"] != nil && device["os_version"] != nil && device["locale"] != nil)

    let crumbs = (r["breadcrumbs"]?.arrayValue ?? []).compactMap(\.objectValue)
    let api = try #require(crumbs.first { $0["type"] == "api" })
    #expect(api["message"] == "GET /rest/v1/orders?select&id 500")
    #expect(api["level"] == "error")
    let data = try #require(api["data"]?.objectValue)
    #expect(data["method"] == "GET")
    #expect(data["url"] == "/rest/v1/orders?select&id")
    #expect(data["status"] == 500)
    #expect(data["error_code"] == "XX000")
    #expect(data["ms"]?.intValue != nil)
    #expect(crumbs.last?["message"] == "tapped Checkout")
    #expect(!crumbs.contains { $0["message"]?.stringValue?.contains("/crashes/v1/") == true })

    let report = try #require(CrashServerProtocol.requests.value.first { $0.request.url?.path.hasSuffix("/report") == true })
    #expect(report.request.value(forHTTPHeaderField: "apikey") == "anon-key")
    #expect(report.request.value(forHTTPHeaderField: "Authorization") == "Bearer anon-key")
    #expect(c.crashes.queuedReports.isEmpty)
    #expect(CrashesClient.loadQueue(in: dir).isEmpty)
    c.crashes.stop()
  }

  @Test
  func beforeSendReturningNilDropsTheReport() async throws {
    CrashServerProtocol.reset()
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeCrashClient()
    c.crashes.start(captureUnhandled: false, directory: dir) { report in
      report.exception.message.contains("secret") ? nil : report
    }
    c.crashes.captureMessage("the secret thing")
    c.crashes.captureMessage("state that should never happen")
    await c.crashes.flush()
    let reports = CrashServerProtocol.reports()
    #expect(reports.count == 1)
    #expect(reports.first?["exception"]?.objectValue?["type"] == "Message")
    #expect(reports.first?["exception"]?.objectValue?["message"] == "state that should never happen")
    c.crashes.stop()
  }

  @Test
  func notFoundStopsSending() async throws {
    CrashServerProtocol.reset()
    CrashServerProtocol.reportStatus.setValue(404)
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeCrashClient()
    c.crashes.start(captureUnhandled: false, directory: dir)
    c.crashes.captureError(CheckoutFailed())
    await c.crashes.flush()
    #expect(CrashServerProtocol.bodies("/crashes/v1/report").count == 1)
    #expect(c.crashes.queuedReports.isEmpty)
    #expect(CrashesClient.loadQueue(in: dir).isEmpty)

    c.crashes.captureError(CheckoutFailed())
    await c.crashes.flush()
    #expect(CrashServerProtocol.bodies("/crashes/v1/report").count == 1, "no more sends this run")
    c.crashes.stop()
  }

  @Test
  func failedSendStaysOnDiskAndIsSentOnTheNextStart() async throws {
    CrashServerProtocol.reset()
    CrashServerProtocol.reportStatus.setValue(503)
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = makeCrashClient()
    first.crashes.start(release: "2.0", captureUnhandled: false, directory: dir)
    first.crashes.captureError(CheckoutFailed())
    await first.crashes.flush()
    #expect(CrashServerProtocol.bodies("/crashes/v1/report").count >= 1)
    #expect(CrashesClient.loadQueue(in: dir).count == 1, "kept on disk")
    first.crashes.stop()

    CrashServerProtocol.reset()
    let second = makeCrashClient()
    second.crashes.start(release: "2.0", captureUnhandled: false, directory: dir)
    await second.crashes.flush()
    let reports = CrashServerProtocol.reports()
    #expect(reports.count == 1)
    #expect(reports.first?["exception"]?.objectValue?["message"] == "card declined")
    #expect(CrashesClient.loadQueue(in: dir).isEmpty)
    second.crashes.stop()
  }

  @Test
  func queueOnDiskIsCappedAt30() async throws {
    CrashServerProtocol.reset()
    CrashServerProtocol.reportStatus.setValue(503)
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeCrashClient()
    c.crashes.start(captureUnhandled: false, directory: dir)
    for i in 0..<35 { c.crashes.captureMessage("m\(i)") }
    await c.crashes.flush()
    let queue = CrashesClient.loadQueue(in: dir)
    #expect(queue.count == 30)
    #expect(queue.first?.exception.message == "m5")
    c.crashes.stop()
  }

  @Test
  func sessionIsSentOnceADay() async throws {
    CrashServerProtocol.reset()
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = makeCrashClient()
    first.crashes.start(release: "3.1", environment: "staging", captureUnhandled: false, directory: dir)
    await first.crashes.flush()
    let sessions = CrashServerProtocol.bodies("/crashes/v1/session")
    #expect(sessions.count == 1)
    #expect(sessions.first?["release"] == "3.1")
    #expect(sessions.first?["environment"] == "staging")
    let install = try #require(sessions.first?["install_id"]?.stringValue)
    #expect(!install.isEmpty)
    first.crashes.stop()

    let second = makeCrashClient()
    second.crashes.start(release: "3.1", environment: "staging", captureUnhandled: false, directory: dir)
    await second.crashes.flush()
    #expect(CrashServerProtocol.bodies("/crashes/v1/session").count == 1, "same day and release: not again")
    second.crashes.stop()

    let third = makeCrashClient()
    third.crashes.start(release: "3.2", captureUnhandled: false, directory: dir)
    await third.crashes.flush()
    let all = CrashServerProtocol.bodies("/crashes/v1/session")
    #expect(all.count == 2, "a new release counts again")
    #expect(all.last?["install_id"]?.stringValue == install, "the install id is kept")
    third.crashes.stop()
  }
}

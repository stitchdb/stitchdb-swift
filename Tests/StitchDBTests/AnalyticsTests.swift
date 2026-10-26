import ConcurrencyExtras
import Foundation
import Testing

@testable import StitchDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A fake analytics (and crash reporting) server of its own, so these tests do not share state with CrashesTests when
/// the suites run in parallel: `trackStatus` is the answer to `/analytics/v1/track`, every request is recorded.
final class AnalyticsServerProtocol: URLProtocol {
  static let trackStatus = LockIsolated(200)
  static let requests = LockIsolated<[(request: URLRequest, body: AnyJSON)]>([])

  static func reset() {
    trackStatus.setValue(200)
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

  private static func respond(_ request: URLRequest) -> (Int, AnyJSON) {
    let json = (try? JSONDecoder().decode(AnyJSON.self, from: CrashServerProtocol.body(of: request))) ?? .null
    requests.withValue { $0.append((request, json)) }
    let path = request.url?.path ?? ""
    if path.hasSuffix("/analytics/v1/track") {
      let status = trackStatus.value
      return (status, status == 200 ? ["received": 1, "dropped": 0] : ["message": "no"])
    }
    if path.hasSuffix("/analytics/v1/opt-out") { return (200, ["ok": true]) }
    if path.hasSuffix("/crashes/v1/report") { return (200, ["received": 1, "stored": 1, "dropped": 0, "issues": []]) }
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

/// A project URL of its own per test, so each test gets its own analytics directory (one per project).
private func projectURL() -> URL {
  let letters = "abcdefghijklmnopqrstuvwxyz"
  let ref = String((0..<16).map { _ in letters.randomElement()! })
  return URL(string: "https://\(ref).stitchdb.com")!
}

private func makeAnalyticsClient(_ url: URL) -> StitchClient {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [AnalyticsServerProtocol.self]
  return StitchClient(
    stitchURL: url,
    stitchKey: "anon-key",
    options: StitchClientOptions(
      auth: StitchClientOptions.AuthOptions(storage: AuthLocalStorageMock(), autoRefreshToken: false),
      global: StitchClientOptions.GlobalOptions(session: URLSession(configuration: config))
    )
  )
}

private func trackBodies() -> [JSONObject] { AnalyticsServerProtocol.bodies("/analytics/v1/track") }

private func eventNames(_ body: JSONObject?) -> [String] {
  (body?["events"]?.arrayValue ?? []).compactMap { $0.objectValue?["name"]?.stringValue }
}

@Suite(.serialized)
struct AnalyticsTests {
  @Test
  func eventsTrackedBeforeStartAreSentInABatchWithTheAnonymousID() async throws {
    AnalyticsServerProtocol.reset()
    let url = projectURL()
    let dir = StitchClient.analyticsDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeAnalyticsClient(url)

    c.analytics.track("app_open")
    c.analytics.track("bad name!")  // dropped: not a valid name
    await c.analytics.flush()
    #expect(trackBodies().isEmpty, "nothing is sent before start")
    #expect(c.analytics.queuedEvents.map(\.name) == ["app_open"])

    c.analytics.start(release: "2.0.0", beforeSend: { $0.props["secret"] != nil ? nil : $0 }, flushInterval: 60)
    c.analytics.track("purchase", props: ["plan": "pro", "amount": 29])
    c.analytics.track("checkout", props: ["secret": true])  // dropped by beforeSend
    await c.analytics.flush()

    let bodies = trackBodies()
    #expect(bodies.count >= 1)
    #expect(bodies.flatMap { eventNames($0) } == ["app_open", "purchase"])
    let body = try #require(bodies.last)
    #expect(body["anon_id"]?.stringValue == c.analytics.anonymousId)
    #expect(!c.analytics.anonymousId.isEmpty)
    #expect(body["session_id"]?.stringValue?.isEmpty == false)
    #expect(body["release"] == "2.0.0")
    #expect(body["platform"] == "swift")
    #expect(body["os"]?.stringValue?.isEmpty == false)
    if let country = body["country"]?.stringValue { #expect(country.count == 2 && country == country.uppercased()) }
    let purchase = try #require(bodies.flatMap { $0["events"]?.arrayValue ?? [] }.last?.objectValue)
    #expect(purchase["props"] == ["plan": "pro", "amount": 29])
    #expect(purchase["at"]?.stringValue?.isEmpty == false)

    let request = try #require(
      AnalyticsServerProtocol.requests.value.first { $0.request.url?.path.hasSuffix("/analytics/v1/track") == true }
    )
    #expect(request.request.httpMethod == "POST")
    #expect(request.request.value(forHTTPHeaderField: "apikey") == "anon-key")
    #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer anon-key")
    #expect(c.analytics.queuedEvents.isEmpty)
    #expect(AnalyticsClient.loadQueue(in: dir).isEmpty)
    c.analytics.stop()
  }

  @Test
  func analyticsCallsAreNotCrashBreadcrumbs() async throws {
    AnalyticsServerProtocol.reset()
    let url = projectURL()
    let dir = StitchClient.analyticsDirectory(for: url)
    let crashDir = FileManager.default.temporaryDirectory.appendingPathComponent("crashes-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: dir)
      try? FileManager.default.removeItem(at: crashDir)
    }
    let c = makeAnalyticsClient(url)
    c.crashes.start(captureUnhandled: false, directory: crashDir)
    c.analytics.start(flushInterval: 60)
    c.analytics.track("app_open")
    await c.analytics.flush()
    _ = try? await c.from("orders").select("id").execute()
    c.crashes.captureMessage("after tracking")
    await c.crashes.flush()

    #expect(trackBodies().count == 1)
    let report = try #require(AnalyticsServerProtocol.reports().first)
    let crumbs = (report["breadcrumbs"]?.arrayValue ?? []).compactMap { $0.objectValue?["message"]?.stringValue }
    #expect(crumbs.contains { $0.contains("/rest/v1/orders") })
    #expect(!crumbs.contains { $0.contains("/analytics/v1/") })
    c.analytics.stop()
    c.crashes.stop()
  }

  @Test
  func optOutDeletesAndNothingIsSentAfter() async throws {
    AnalyticsServerProtocol.reset()
    let url = projectURL()
    let dir = StitchClient.analyticsDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeAnalyticsClient(url)
    c.analytics.start(flushInterval: 60)
    #expect(!c.analytics.isOptedOut)

    await c.analytics.optOut()
    let optOut = try #require(
      AnalyticsServerProtocol.requests.value.first { $0.request.url?.path.hasSuffix("/analytics/v1/opt-out") == true }
    )
    #expect(optOut.request.httpMethod == "POST")
    #expect(optOut.body == [:])
    #expect(optOut.request.value(forHTTPHeaderField: "apikey") == "anon-key")
    #expect(c.analytics.isOptedOut)

    c.analytics.track("app_open")
    await c.analytics.flush()
    #expect(trackBodies().isEmpty, "nothing is tracked or sent while opted out")
    #expect(c.analytics.queuedEvents.isEmpty)

    let again = makeAnalyticsClient(url)
    #expect(again.analytics.isOptedOut, "remembered on the device")
    #expect(again.analytics.anonymousId == c.analytics.anonymousId, "the anonymous id is kept")

    await again.analytics.optIn()
    let optIn = AnalyticsServerProtocol.requests.value.last
    #expect(optIn?.request.url?.path.hasSuffix("/analytics/v1/opt-out") == true)
    #expect(optIn?.request.httpMethod == "DELETE")
    #expect(!again.analytics.isOptedOut)
    again.analytics.start(flushInterval: 60)
    again.analytics.track("app_open")
    await again.analytics.flush()
    #expect(trackBodies().count == 1)
    c.analytics.stop()
    again.analytics.stop()
  }

  @Test
  func notFoundStopsSending() async throws {
    AnalyticsServerProtocol.reset()
    AnalyticsServerProtocol.trackStatus.setValue(404)
    let url = projectURL()
    let dir = StitchClient.analyticsDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeAnalyticsClient(url)
    c.analytics.start(flushInterval: 60)
    c.analytics.track("app_open")
    await c.analytics.flush()
    #expect(trackBodies().count == 1)
    #expect(c.analytics.queuedEvents.isEmpty)
    #expect(AnalyticsClient.loadQueue(in: dir).isEmpty)

    c.analytics.track("purchase")
    await c.analytics.flush()
    #expect(trackBodies().count == 1, "no more sends this run")
    c.analytics.stop()
  }

  @Test
  func failedSendStaysOnDiskAndIsSentOnTheNextStart() async throws {
    AnalyticsServerProtocol.reset()
    AnalyticsServerProtocol.trackStatus.setValue(503)
    let url = projectURL()
    let dir = StitchClient.analyticsDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = makeAnalyticsClient(url)
    first.analytics.start(release: "2.0", flushInterval: 60)
    first.analytics.track("purchase", props: ["plan": "pro"])
    await first.analytics.flush()
    #expect(trackBodies().count >= 1)
    #expect(AnalyticsClient.loadQueue(in: dir).map(\.name) == ["purchase"], "kept on disk")
    first.analytics.stop()

    AnalyticsServerProtocol.reset()
    let second = makeAnalyticsClient(url)
    second.analytics.start(release: "2.0", flushInterval: 60)
    await second.analytics.flush()
    let bodies = trackBodies()
    #expect(bodies.count == 1)
    #expect(eventNames(bodies.first) == ["purchase"])
    #expect(bodies.first?["anon_id"]?.stringValue == first.analytics.anonymousId)
    #expect(AnalyticsClient.loadQueue(in: dir).isEmpty)
    second.analytics.stop()
  }

  @Test
  func twentyWaitingEventsAreSentWithoutFlush() async throws {
    AnalyticsServerProtocol.reset()
    let url = projectURL()
    let dir = StitchClient.analyticsDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeAnalyticsClient(url)
    c.analytics.start(flushInterval: 60)
    for i in 0..<20 { c.analytics.track("step \(i)") }
    for _ in 0..<100 where trackBodies().flatMap({ eventNames($0) }).count < 20 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(trackBodies().flatMap { eventNames($0) }.count == 20)
    c.analytics.stop()
  }

  @Test
  func validEventNames() {
    #expect(AnalyticsClient.isValidName("purchase"))
    #expect(AnalyticsClient.isValidName("$pageview"))
    #expect(AnalyticsClient.isValidName("signup: step 2/3 - done.v2"))
    #expect(AnalyticsClient.isValidName(String(repeating: "a", count: 64)))
    #expect(!AnalyticsClient.isValidName(String(repeating: "a", count: 65)))
    #expect(!AnalyticsClient.isValidName(""))
    #expect(!AnalyticsClient.isValidName(" leading space"))
    #expect(!AnalyticsClient.isValidName("bad name!"))
    #expect(!AnalyticsClient.isValidName("émoji"))
  }
}

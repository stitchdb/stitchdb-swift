import ConcurrencyExtras
import Foundation
import Testing

@testable import StitchDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A fake links server of its own, so these tests do not share state with the other suites when they run in parallel:
/// every request is recorded.
final class LinksServerProtocol: URLProtocol {
  static let requests = LockIsolated<[(request: URLRequest, body: AnyJSON)]>([])

  static let link: JSONObject = [
    "code": "aB3kP9x", "url": "https://go.shop.test/l/aB3kP9x", "path": "/product/42", "data": ["promo": "SPRING"],
  ]

  static func full(_ extra: JSONObject = [:]) -> JSONObject {
    var l = link
    for (k, v) in [
      "web_url": AnyJSON.null, "ios_url": .null, "android_url": .null, "title": .null, "description": .null,
      "image_url": .null, "expires_at": .null, "disabled": false, "source": "api", "created_by": .null, "clicks": 3,
      "opens": 2, "installs": 1, "last_click_at": .null, "created_at": "2026-10-26T00:00:00Z",
      "updated_at": "2026-10-26T00:00:00Z",
    ] as JSONObject { l[k] = v }
    for (k, v) in extra { l[k] = v }
    return l
  }

  static var last: (request: URLRequest, body: AnyJSON)? { requests.value.last }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  private static func respond(_ request: URLRequest) -> (Int, AnyJSON) {
    let json = (try? JSONDecoder().decode(AnyJSON.self, from: CrashServerProtocol.body(of: request))) ?? .null
    requests.withValue { $0.append((request, json)) }
    let path = request.url?.path ?? ""
    let method = request.httpMethod ?? "GET"
    if path.hasSuffix("/resolve/old") { return (410, ["message": "This link has expired", "code": "old"]) }
    if path.contains("/links/v1/resolve/") { return (200, .object(link)) }
    if path.hasSuffix("/links/v1/deferred") {
      if json.objectValue?["platform"] == "ios" {
        var m = link
        m["matched_by"] = "network"
        return (200, ["match": .object(m)])
      }
      return (200, ["match": .null])
    }
    if path.hasSuffix("/links/v1/links"), method == "POST" {
      var made = full()
      for (k, v) in json.objectValue ?? [:] { made[k] = v }
      return (201, .object(made))
    }
    if path.hasSuffix("/links/v1/links") { return (200, ["links": [.object(full())], "total": 1]) }
    if path.hasSuffix("/links/v1/links/taken") { return (409, ["message": "That code is taken"]) }
    if path.contains("/links/v1/links/") {
      switch method {
      case "PATCH": return (200, .object(full(json.objectValue ?? [:])))
      case "DELETE": return (200, ["deleted": "summer"])
      default:
        return (
          200,
          [
            "link": .object(full()), "days": 7,
            "daily": [["day": "2026-10-26", "clicks": 3, "opens": 2, "installs": 1]],
            "platforms": [["k": "ios", "n": 2]], "countries": [["k": "DE", "n": 3]], "outcomes": [["k": "store", "n": 1]],
            "referrers": [],
          ]
        )
      }
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

/// A project URL of its own per test, so each test gets its own links directory (one per project).
private func projectURL() -> URL {
  let letters = "abcdefghijklmnopqrstuvwxyz"
  let ref = String((0..<16).map { _ in letters.randomElement()! })
  return URL(string: "https://\(ref).stitchdb.com")!
}

private func makeLinksClient(_ url: URL) -> StitchClient {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [LinksServerProtocol.self]
  return StitchClient(
    stitchURL: url,
    stitchKey: "anon-key",
    options: StitchClientOptions(
      auth: StitchClientOptions.AuthOptions(storage: AuthLocalStorageMock(), autoRefreshToken: false),
      global: StitchClientOptions.GlobalOptions(session: URLSession(configuration: config))
    )
  )
}

@Suite(.serialized)
struct LinksTests {
  @Test
  func codeFromShortLinks() {
    #expect(LinksClient.codeFrom("https://go.shop.test/l/aB3kP9x?utm=1") == "aB3kP9x")
    #expect(LinksClient.codeFrom("https://go.shop.test/l/aB3kP9x/") == "aB3kP9x")
    #expect(LinksClient.codeFrom(URL(string: "https://abc.p.stitchdb.com/l/x_-9")!) == "x_-9")
    #expect(LinksClient.codeFrom("https://go.shop.test/product/42") == nil)
    #expect(LinksClient.codeFrom("https://go.shop.test/l/a/b") == nil)
    #expect(LinksClient.codeFrom("https://go.shop.test/l/") == nil)
    #expect(LinksClient.codeFrom("https://go.shop.test/l/bad%20code") == nil)
    #expect(LinksClient.codeFrom("summer") == "summer")
    #expect(LinksClient.codeFrom("  summer\n") == "summer")
    #expect(LinksClient.codeFrom("not a code") == nil)
    #expect(LinksClient.codeFrom(String(repeating: "a", count: 65)) == nil)
    #expect(LinksClient.codeFrom("") == nil)
  }

  @Test
  func resolveSendsTheKeyAndPlatform() async throws {
    LinksServerProtocol.requests.setValue([])
    let url = projectURL()
    let c = makeLinksClient(url)

    let link = try #require(try await c.links.resolve("https://go.shop.test/l/aB3kP9x", platform: .ios))
    #expect(link == AppLink(code: "aB3kP9x", url: "https://go.shop.test/l/aB3kP9x", path: "/product/42",
                            data: ["promo": "SPRING"]))
    let sent = try #require(LinksServerProtocol.last).request
    #expect(sent.httpMethod == "GET")
    #expect(sent.url?.absoluteString == "\(url.absoluteString)/links/v1/resolve/aB3kP9x?platform=ios")
    #expect(sent.value(forHTTPHeaderField: "apikey") == "anon-key")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer anon-key")

    _ = try await c.links.resolve(URL(string: "https://go.shop.test/l/aB3kP9x")!, platform: nil)
    #expect(LinksServerProtocol.last?.request.url?.query == nil)

    let count = LinksServerProtocol.requests.value.count
    #expect(try await c.links.resolve("https://shop.test/about") == nil)
    #expect(LinksServerProtocol.requests.value.count == count, "not a short link: no request")
  }

  @Test
  func expiredLinkThrows410() async throws {
    let c = makeLinksClient(projectURL())
    do {
      _ = try await c.links.resolve("old")
      Issue.record("expected an error")
    } catch let error as LinksError {
      #expect(error.status == 410)
      #expect(error.message == "This link has expired")
    }
  }

  @Test
  func deferredIsAskedOncePerInstall() async throws {
    LinksServerProtocol.requests.setValue([])
    let url = projectURL()
    let dir = StitchClient.linksDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = makeLinksClient(url)

    #expect(!c.links.isDeferredChecked)
    let first = try #require(try await c.links.deferred())
    #expect(first.matchedBy == "network")
    #expect(first.path == "/product/42")
    #expect(LinksServerProtocol.last?.body == ["platform": "ios"])
    #expect(LinksServerProtocol.last?.request.httpMethod == "POST")
    #expect(c.links.isDeferredChecked)

    let count = LinksServerProtocol.requests.value.count
    #expect(try await c.links.deferred() == nil)
    #expect(LinksServerProtocol.requests.value.count == count, "already checked: no request")

    // remembered on the device: a new client of the same project does not ask again
    #expect(try await makeLinksClient(url).links.deferred() == nil)
    #expect(LinksServerProtocol.requests.value.count == count)

    #expect(try await c.links.deferred(platform: .android, referrer: "stitch_link=x", force: true) == nil)
    #expect(LinksServerProtocol.last?.body == ["platform": "android", "referrer": "stitch_link=x"])
  }

  @Test
  func deferredIsNotMarkedCheckedOnAnError() async throws {
    let url = URL(string: "https://\(UUID().uuidString.lowercased().prefix(8))nolinks.stitchdb.com")!
    let dir = StitchClient.linksDirectory(for: url)
    defer { try? FileManager.default.removeItem(at: dir) }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailingLinksProtocol.self]
    let c = StitchClient(
      stitchURL: url, stitchKey: "anon-key",
      options: StitchClientOptions(
        auth: StitchClientOptions.AuthOptions(storage: AuthLocalStorageMock(), autoRefreshToken: false),
        global: StitchClientOptions.GlobalOptions(session: URLSession(configuration: config))
      )
    )
    await #expect(throws: LinksError.self) { try await c.links.deferred() }
    #expect(!c.links.isDeferredChecked)
  }

  @Test
  func createListGetUpdateRemove() async throws {
    LinksServerProtocol.requests.setValue([])
    let url = projectURL()
    let base = "\(url.absoluteString)/links/v1"
    let c = makeLinksClient(url)

    let made = try await c.links.create(
      LinkInput(
        path: "/invite/7", data: ["from": "ana"], title: "Join me",
        expiresAt: Date(timeIntervalSince1970: 1_796_083_200)  // 2026-12-01T00:00:00Z
      )
    )
    #expect(made.path == "/invite/7")
    #expect(made.title == "Join me")
    #expect(made.data == ["from": "ana"])
    #expect(made.clicks == 3)
    let createBody = try #require(LinksServerProtocol.last?.body.objectValue)
    #expect(createBody["expires_at"] == "2026-12-01T00:00:00.000Z")
    #expect(createBody["data"] == ["from": "ana"])
    #expect(createBody["web_url"] == nil, "fields left nil are not sent")
    #expect(LinksServerProtocol.last?.request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let page = try await c.links.list(search: "spring", limit: 5)
    #expect(page.total == 1)
    #expect(page.links.first?.code == "aB3kP9x")
    #expect(LinksServerProtocol.last?.request.url?.absoluteString == "\(base)/links?q=spring&limit=5")
    _ = try await c.links.list()
    #expect(LinksServerProtocol.last?.request.url?.absoluteString == "\(base)/links")

    let stats = try await c.links.get("summer", days: 7)
    #expect(LinksServerProtocol.last?.request.url?.absoluteString == "\(base)/links/summer?days=7")
    #expect(stats.days == 7)
    #expect(stats.daily.first?.clicks == 3)
    #expect(stats.countries == [LinkStats.Count(k: "DE", n: 3)])
    #expect(stats.link.installs == 1)

    let changed = try await c.links.update("summer", LinkInput(disabled: true))
    #expect(changed.disabled)
    #expect(LinksServerProtocol.last?.request.httpMethod == "PATCH")
    #expect(LinksServerProtocol.last?.body == ["disabled": true])

    _ = try await c.links.update("summer", LinkInput(title: "", removeExpiry: true))
    #expect(LinksServerProtocol.last?.body == ["title": "", "expires_at": .null])

    #expect(try await c.links.remove("summer") == "summer")
    #expect(LinksServerProtocol.last?.request.httpMethod == "DELETE")
    #expect(LinksServerProtocol.last?.request.url?.absoluteString == "\(base)/links/summer")

    do {
      _ = try await c.links.update("taken", LinkInput(code: "x"))
      Issue.record("expected an error")
    } catch let error as LinksError {
      #expect(error.status == 409)
      #expect(error.message == "That code is taken")
    }
  }
}

/// Every request fails with a 429.
final class FailingLinksProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"message":"Too many requests"}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

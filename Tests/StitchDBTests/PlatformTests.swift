import ConcurrencyExtras
import Foundation
import Testing

@testable import Auth
@testable import StitchDB

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A fake platform server: each test sets `handler`, every request is recorded.
final class PlatformServerProtocol: URLProtocol {
  typealias Handler = @Sendable (_ request: URLRequest, _ body: AnyJSON) -> (Int, AnyJSON)

  static let requests = LockIsolated<[(request: URLRequest, body: AnyJSON)]>([])
  static let handler = LockIsolated<Handler>({ _, _ in (404, ["message": "not found"]) })
  /// Raw answers (for CSV) by path suffix.
  static let rawAnswers = LockIsolated<[String: String]>([:])

  static func reset(_ handler: @escaping Handler) {
    requests.setValue([])
    rawAnswers.setValue([:])
    self.handler.setValue(handler)
  }

  static var last: (request: URLRequest, body: AnyJSON)? { requests.value.last }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let request = self.request
    let json = (try? JSONDecoder().decode(AnyJSON.self, from: CrashServerProtocol.body(of: request))) ?? .null
    Self.requests.withValue { $0.append((request, json)) }
    let path = request.url?.path ?? ""
    let data: Data
    let code: Int
    if let raw = Self.rawAnswers.value.first(where: { path.hasSuffix($0.key) }) {
      code = 200
      data = Data(raw.value.utf8)
    } else {
      let (c, answer) = Self.handler.value(request, json)
      code = c
      data = answer == .null ? Data() : ((try? JSONEncoder().encode(answer)) ?? Data())
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

func platformProjectURL() -> URL {
  let letters = "abcdefghijklmnopqrstuvwxyz"
  let ref = String((0..<16).map { _ in letters.randomElement()! })
  return URL(string: "https://\(ref).stitchdb.com")!
}

/// Keeps what Auth stores (the PKCE code verifier) in memory.
final class MemoryAuthStorage: AuthLocalStorage {
  let items = LockIsolated<[String: Data]>([:])
  func store(key: String, value: Data) throws { items.withValue { $0[key] = value } }
  func retrieve(key: String) throws -> Data? { items.value[key] }
  func remove(key: String) throws { items.withValue { _ = $0.removeValue(forKey: key) } }
}

func makePlatformClient(
  _ url: URL = platformProjectURL(), storage: any AuthLocalStorage = AuthLocalStorageMock()
) -> StitchClient {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [PlatformServerProtocol.self]
  return StitchClient(
    stitchURL: url,
    stitchKey: "anon-key",
    options: StitchClientOptions(
      auth: StitchClientOptions.AuthOptions(storage: storage, autoRefreshToken: false),
      global: StitchClientOptions.GlobalOptions(session: URLSession(configuration: config))
    )
  )
}

extension URLRequest {
  var queryDict: [String: String] {
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
  }
}

@Suite(.serialized)
struct PlatformTests {
  // MARK: Push

  @Test
  func pushRegistersAndSends() async throws {
    PlatformServerProtocol.reset { request, _ in
      let path = request.url!.path
      if path.hasSuffix("/push/v1/devices") { return (200, ["id": "d1", "platform": "ios", "topics": ["news"]]) }
      if path.hasSuffix("/push/v1/send") { return (202, ["id": 12, "status": "queued"]) }
      if path.hasSuffix("/push/v1/inbox/read") { return (200, ["marked": 3]) }
      return (404, ["message": "nope", "error_code": "not_found"])
    }
    let client = makePlatformClient()
    let token = Data([0xAB, 0x01, 0xFF] + Array(repeating: 0x10, count: 29))
    #expect(PushClient.hexToken(token).hasPrefix("ab01ff1010"))
    _ = try await client.push.register(.apns(token, topics: ["news"]))
    let reg = try #require(PlatformServerProtocol.last)
    #expect(reg.request.httpMethod == "POST")
    #expect(reg.request.value(forHTTPHeaderField: "apikey") == "anon-key")
    #expect(reg.body.objectValue?["platform"] == "ios")
    #expect(reg.body.objectValue?["token"]?.stringValue == PushClient.hexToken(token))
    #expect(reg.body.objectValue?["topics"] == ["news"])

    _ = try await client.push.send(PushMessage(topic: "news", title: "Hi", body: "There"))
    #expect(PlatformServerProtocol.last?.body.objectValue?["topic"] == "news")
    #expect(PlatformServerProtocol.last?.body.objectValue?["title"] == "Hi")

    _ = try await client.push.markAllRead()
    #expect(PlatformServerProtocol.last?.body.objectValue?["all"] == true)

    await #expect(throws: PushError.self) { _ = try await client.push.status(99) }
    do {
      _ = try await client.push.status(99)
    } catch let error as PushError {
      #expect(error.status == 404)
      #expect(error.code == "not_found")
      #expect(error.message == "nope")
    }
  }

  @Test
  func pushWebDeviceBody() throws {
    let device = PushDevice.web(endpoint: "https://push.example.test/abc", p256dh: "p", auth: "a")
    let json = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(device))
    #expect(json["platform"] == "web")
    #expect(json["subscription"]?.objectValue?["endpoint"] == "https://push.example.test/abc")
    #expect(json["subscription"]?.objectValue?["keys"]?.objectValue?["p256dh"] == "p")
  }

  // MARK: Purchases

  @Test
  func purchasesSyncAndEntitlements() async throws {
    PlatformServerProtocol.reset { request, _ in
      let path = request.url!.path
      let purchase: AnyJSON = [
        "id": 7, "store": "apple", "product_id": "pro.monthly", "kind": "subscription", "status": "active",
        "entitlements": ["pro"], "expires_at": "2027-01-01T00:00:00Z",
      ]
      if path.hasSuffix("/purchases/v1/me") { return (200, ["entitlements": ["pro"], "purchases": [purchase]]) }
      if path.hasSuffix("/purchases/v1/sync") { return (200, ["entitlements": ["pro"], "purchase": purchase]) }
      return (404, ["message": "not found"])
    }
    let client = makePlatformClient()
    _ = try await client.purchases.sync(signedTransaction: "eyJ.jws.sig")
    let body = try #require(PlatformServerProtocol.last?.body.objectValue)
    #expect(body["store"] == "apple")
    #expect(body["signed_transaction"] == "eyJ.jws.sig")
    #expect(try await client.purchases.hasEntitlement("pro"))
    #expect(try await client.purchases.hasEntitlement("team") == false)
  }

  // MARK: Orgs

  @Test
  func orgsCallFunctions() async throws {
    PlatformServerProtocol.reset { request, body in
      let path = request.url!.path
      if path.hasSuffix("/rest/v1/rpc/org_create") {
        return (200, ["id": "o1", "name": body.objectValue?["name"] ?? .null, "slug": "acme", "role": "owner"])
      }
      if path.hasSuffix("/rest/v1/rpc/org_list") { return (200, [["id": "o1", "name": "Acme", "slug": "acme"]]) }
      if path.hasSuffix("/rest/v1/rpc/org_leave") { return (204, .null) }
      return (404, ["code": "PGRST202", "message": "Could not find the function public.org_x"])
    }
    let client = makePlatformClient()
    let org = try await client.orgs.create(name: "Acme")
    #expect(org.id == "o1")
    #expect(org.name == "Acme")
    let createCall = try #require(
      PlatformServerProtocol.requests.value.first { $0.request.url!.path.hasSuffix("org_create") }
    )
    #expect(createCall.body.objectValue?["name"] == "Acme")
    #expect(try await client.orgs.list().map(\.id) == ["o1"])
    try await client.orgs.leave("o1")
    #expect(PlatformServerProtocol.last?.body.objectValue?["org"] == "o1")
    #expect(OrgsClient.headerName == "x-org-id")
    await #expect(throws: OrgsError.self) { _ = try await client.orgs.members("o1") }
  }

  // MARK: Search

  @Test
  func searchPostsTheQuery() async throws {
    PlatformServerProtocol.reset { _, _ in
      (200, ["data": [["id": 1, "title": "Refunds"]], "scores": [["score": 0.9, "keyword_rank": 1, "semantic_rank": 2]], "mode": "hybrid"])
    }
    let client = makePlatformClient()
    let results = try await client.search("articles", "refund", options: SearchOptions(limit: 5, mode: .hybrid))
    let last = try #require(PlatformServerProtocol.last)
    #expect(last.request.url!.path.hasSuffix("/search/v1/articles"))
    #expect(last.body.objectValue?["q"] == "refund")
    #expect(last.body.objectValue?["limit"] == 5)
    #expect(last.body.objectValue?["mode"] == "hybrid")
    #expect(results.data.first?["title"] == "Refunds")
    #expect(results.mode == .hybrid)
    #expect(results.scores.first?.semanticRank == 2)
  }

  // MARK: Jobs

  @Test
  func jobsStartGetCancelLogs() async throws {
    let run: JSONObject = ["id": "r1", "job": "export", "status": "queued", "mode": "long", "payload": ["a": 1]]
    PlatformServerProtocol.reset { request, _ in
      let path = request.url!.path
      if path.hasSuffix("/logs") {
        return (200, ["lines": [["seq": 1, "at": "2026-11-01T00:00:00Z", "level": "info", "line": "go"]], "next": 1, "more": false])
      }
      if path.hasSuffix("/jobs/v1/runs"), request.httpMethod == "GET" { return (200, ["runs": [.object(run)]]) }
      return (200, .object(run))
    }
    let client = makePlatformClient()
    let started = try await client.jobs.start(
      "export", payload: ["a": 1], options: JobStartOptions(idempotencyKey: "k1", mode: .long)
    )
    #expect(started.mode == .long)
    let body = try #require(PlatformServerProtocol.last?.body.objectValue)
    #expect(body["job"] == "export")
    #expect(body["mode"] == "long")
    #expect(body["idempotency_key"] == "k1")
    _ = try await client.jobs.cancel("r1")
    #expect(PlatformServerProtocol.last?.request.url?.path.hasSuffix("/runs/r1/cancel") == true)
    _ = try await client.jobs.retry("r1")
    #expect(PlatformServerProtocol.last?.request.url?.path.hasSuffix("/runs/r1/retry") == true)
    let runs = try await client.jobs.list(job: "export", status: .queued, limit: 10)
    #expect(runs.count == 1)
    #expect(PlatformServerProtocol.last?.request.queryDict["status"] == "queued")
    let logs = try await client.jobs.logs("r1", after: 0)
    #expect(logs.lines.first?.line == "go")
    #expect(PlatformServerProtocol.last?.request.queryDict["after"] == "0")
  }

  // MARK: Flags

  @Test
  func flagsLoadAndRead() async throws {
    PlatformServerProtocol.reset { _, _ in
      (
        200,
        [
          "flags": [
            "new-checkout": ["value": true, "variation": 0, "reason": "rule:0"],
            "upload-limit-mb": ["value": 25, "variation": 1, "reason": "default"],
          ],
          "version": 4, "user_id": .null,
        ]
      )
    }
    let client = makePlatformClient()
    let changed = LockIsolated<[String]>([])
    let token = client.flags.onChange { keys in changed.withValue { $0 += keys } }
    try await client.flags.load(attributes: ["app_version": "2.4.1"], refreshInterval: 0)
    #expect(client.flags.isOn("new-checkout"))
    #expect(client.flags.get("upload-limit-mb", default: 10) == 25)
    #expect(client.flags.get("missing", default: "x") == "x")
    #expect(client.flags.configVersion == 4)
    #expect(changed.value == ["new-checkout", "upload-limit-mb"])
    let body = try #require(PlatformServerProtocol.last?.body.objectValue)
    #expect(body["attributes"]?.objectValue?["app_version"] == "2.4.1")
    #expect(body["anon_id"]?.stringValue?.isEmpty == false)
    token.cancel()
  }

  // MARK: Metering

  @Test
  func meteringRecordUsageExport() async throws {
    PlatformServerProtocol.reset { request, _ in
      if request.url!.path.hasSuffix("/record") { return (200, ["recorded": 1, "duplicates": 0]) }
      return (
        200,
        [
          "from": "a", "to": "b", "group": "month", "customer": "c1", "truncated": false,
          "meters": ["ai_tokens": ["name": "ai_tokens", "unit": "tokens", "aggregation": "sum"]],
          "rows": [["customer": "c1", "meter": "ai_tokens", "period": "2026-11", "value": 1532]],
        ]
      )
    }
    PlatformServerProtocol.rawAnswers.setValue(["/export": "customer,meter,period,value\nc1,ai_tokens,2026-11,1532\n"])
    let client = makePlatformClient()
    let result = try await client.metering.record("ai_tokens", quantity: 1532, customer: "c1", idempotencyKey: "x")
    #expect(result.recorded == 1)
    let body = try #require(PlatformServerProtocol.last?.body.objectValue)
    #expect(body["meter"] == "ai_tokens")
    #expect(body["quantity"]?.doubleValue == 1532 || body["quantity"]?.intValue == 1532)
    #expect(body["idempotency_key"] == "x")
    let usage = try await client.metering.usage(customer: "c1", group: .month)
    #expect(usage.rows.first?.value == 1532)
    #expect(PlatformServerProtocol.last?.request.queryDict["group"] == "month")
    let csv = try await client.metering.exportCSV()
    #expect(csv.hasPrefix("customer,meter"))
    #expect(PlatformServerProtocol.last?.request.queryDict["format"] == "csv")
  }

  // MARK: GraphQL

  @Test
  func graphqlSendsTheDocument() async throws {
    PlatformServerProtocol.reset { request, body in
      if body.objectValue?["operationName"] == "Bad" {
        return (200, ["data": .null, "errors": [["message": "Unknown field"]]])
      }
      return (200, ["data": ["todosCollection": ["edges": []]]])
    }
    let client = makePlatformClient()
    let ok = await client.graphql("query Q($n: Int) { todosCollection(first: $n) { edges { node { id } } } }", variables: ["n": 5])
    #expect(ok.error == nil)
    #expect(ok.data?.objectValue?["todosCollection"] != nil)
    let last = try #require(PlatformServerProtocol.last)
    #expect(last.request.url!.path.hasSuffix("/graphql/v1"))
    #expect(last.body.objectValue?["variables"]?.objectValue?["n"] == 5)
    #expect(last.request.value(forHTTPHeaderField: "apikey") == "anon-key")
    let bad = await client.graphql("{ nope }", operationName: "Bad")
    #expect(bad.error?.message == "Unknown field")
    #expect(bad.errors?.count == 1)
  }

  // MARK: Status

  @Test
  func statusGetAndSubscribe() async throws {
    PlatformServerProtocol.reset { request, body in
      if request.url!.path.hasSuffix("/status/v1/subscribe") {
        if body.objectValue?["email"] == "bad" { return (400, ["message": "Enter a valid e-mail address"]) }
        return (200, ["ok": true, "message": "Check your inbox"])
      }
      return (
        200,
        [
          "title": "Acme status", "description": .null, "url": .null, "overall": "degraded",
          "overall_label": "Partial outage",
          "components": [
            [
              "id": "api", "name": "API", "description": .null, "status": "degraded", "since": .null,
              "response_ms": 120, "checked_at": .null, "uptime_90d": 99.95,
              "history": [["day": "2026-11-01", "status": "operational", "uptime": 100]],
            ]
          ],
          "incidents": [["id": "i1", "title": "Slow API", "impact": "minor", "status": "investigating", "extra": 1]],
          "updated_at": "2026-11-02T00:00:00Z",
        ]
      )
    }
    let client = makePlatformClient()
    let page = try await client.status.get()
    #expect(page.overall == "degraded")
    #expect(page.components.first?.uptime90d == 99.95)
    #expect(page.incidents.first?.raw["extra"] == 1)
    #expect(PlatformServerProtocol.last?.request.url?.path.hasSuffix("/status/v1/status.json") == true)
    let sub = try await client.status.subscribe(email: "ana@example.com")
    #expect(sub.ok)
    #expect(PlatformServerProtocol.last?.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    do {
      try await client.status.subscribe(email: "bad")
      Issue.record("expected an error")
    } catch let error as StatusError {
      #expect(error.status == 400)
    }
    #expect(client.status.badgeURL(component: "api").absoluteString.hasSuffix("/status/v1/badge.svg?component=api"))
  }

  // MARK: Auth

  @Test
  func otpSolvesTheSignupCheckAndSendsTheLocale() async throws {
    let challenge: JSONObject = [
      "algorithm": "SHA-256", "challenge": "1428a5a65936b6fb52c4792e13873f4ed8a20584dd4846b5057535416c287d9d",
      "maxnumber": 5000, "salt": "s4lt", "signature": "sig",
    ]
    PlatformServerProtocol.reset { request, body in
      guard request.url!.path.hasSuffix("/auth/v1/otp") else { return (404, ["message": "not found"]) }
      if body.objectValue?["stitchdb_captcha"] == nil {
        return (400, ["code": 400, "error_code": "captcha_required", "msg": "Solve the check", "challenge": .object(challenge)])
      }
      return (200, [:])
    }
    let url = platformProjectURL()
    SignupLocale.overrides.withValue { $0[url.host!] = "de-AT" }
    defer { SignupLocale.overrides.withValue { _ = $0.removeValue(forKey: url.host!) } }
    let client = makePlatformClient(url)
    try await client.auth.signInWithOTP(email: "ana@example.com", data: ["plan": "free"])
    let calls = PlatformServerProtocol.requests.value.filter { $0.request.url!.path.hasSuffix("/otp") }
    #expect(calls.count == 2)
    let retry = try #require(calls.last?.body.objectValue)
    let answer = try #require(retry["stitchdb_captcha"]?.stringValue)
    let decoded = try JSONDecoder().decode(JSONObject.self, from: try #require(Data(base64Encoded: answer)))
    #expect(decoded["number"] == 1234)
    #expect(decoded["signature"] == "sig")
    #expect(retry["data"]?.objectValue?["plan"] == "free")
    #expect(retry["data"]?.objectValue?["locale"] == "de-AT")
  }

  @Test
  func signupCheckAndLocaleHelpers() throws {
    #expect(SignupCheck.solveSync(["salt": "s4lt", "challenge": "zz", "maxnumber": 10]) == nil)
    #expect(SignupCheck.solveSync(["salt": "s4lt", "challenge": "1428a5a65936b6fb52c4792e13873f4ed8a20584dd4846b5057535416c287d9d", "maxnumber": 100]) == nil)
    #expect(deviceLocale(["en_US_POSIX", "C", "de_AT"]) == "de-AT")
    #expect(deviceLocale(["pt-BR"]) == "pt-BR")
    #expect(deviceLocale(["not a locale!"]) == nil)
    #expect(withLocale(["lang": "fr"], preferred: "de")?["locale"] == nil)
    #expect(withLocale(nil, preferred: "de")?["locale"] == "de")
    #expect(withLocale(["a": 1], preferred: nil) == ["a": 1])
  }

  @Test
  func hostedPageURLAndCodeExchange() async throws {
    let client = makePlatformClient(URL(string: "https://hostedref.stitchdb.com")!, storage: MemoryAuthStorage())
    let url = try client.auth.getHostedPageURL(
      redirectTo: URL(string: "myapp://login")!, view: .signUp, lang: "de"
    )
    #expect(url.absoluteString.hasPrefix("https://hostedref.stitchdb.com/login/v1/?"))
    let q = URLRequest(url: url).queryDict
    #expect(q["redirect_to"] == "myapp://login")
    #expect(q["view"] == "sign-up")
    #expect(q["lang"] == "de")
    #expect(q["code_challenge"]?.isEmpty == false)
    #expect(q["code_challenge_method"] == "s256")

    let user: JSONObject = [
      "id": "0b1c5d3e-1f2a-4b5c-8d9e-0f1a2b3c4d5e", "aud": "authenticated", "app_metadata": [:], "user_metadata": [:],
      "created_at": "2026-11-01T00:00:00Z", "updated_at": "2026-11-01T00:00:00Z",
    ]
    PlatformServerProtocol.reset { request, _ in
      guard request.url!.path.hasSuffix("/login/v1/token") else { return (404, ["message": "not found"]) }
      return (
        200,
        [
          "access_token": "at", "token_type": "bearer", "expires_in": 3600, "expires_at": 4_000_000_000,
          "refresh_token": "rt", "user": .object(user),
        ]
      )
    }
    let session = try await client.auth.exchangeCodeForSession(authCode: "sdbl_abc")
    #expect(session.accessToken == "at")
    let body = try #require(PlatformServerProtocol.last?.body.objectValue)
    #expect(body["code"] == "sdbl_abc")
    #expect(body["code_verifier"]?.stringValue?.isEmpty == false)
  }
}

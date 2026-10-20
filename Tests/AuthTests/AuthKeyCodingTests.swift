import Foundation
import Testing

@testable import Auth

@Suite struct AuthKeyCodingTests {
  struct Sample: Codable, Equatable {
    var redirectTo = "a"; var codeChallengeMethod = "b"; var myURLProperty = "c"; var userID = "d"; var aBC = "e"
    var x1Y2 = "f"; var already_snake = "g"; var ID = "h"; var nonceHTTP2Value = "i"; var emailRedirectTo = "j"
    var data: [String: String] = ["fullName": "Ada", "plain": "x", "Upper": "y"]
  }
  struct Captcha: Codable, Equatable { var email = "a@b.c"; var metaSecurity: AuthMetaSecurity? = .init(captchaToken: "tok") }

  @Test func encodingMatchesFoundation() throws {
    let a = JSONEncoder(); a.keyEncodingStrategy = .convertToSnakeCase; a.outputFormatting = .sortedKeys
    let b = JSONEncoder(); b.keyEncodingStrategy = .custom(AuthKeyCoding.encode); b.outputFormatting = .sortedKeys
    #expect(try a.encode(Sample()) == b.encode(Sample()))
  }

  struct RoundTrip: Codable, Equatable {
    var redirectTo = "a"; var codeChallengeMethod = "b"; var x1Y2 = "c"; var emailRedirectTo = "d"; var userId = "e"
    var data: [String: String] = ["fullName": "Ada", "plain": "x"]
  }

  @Test func decodingMatchesFoundation() throws {
    let json = try { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return try e.encode(RoundTrip()) }()
    let a = JSONDecoder(); a.keyDecodingStrategy = .convertFromSnakeCase
    let b = JSONDecoder(); b.keyDecodingStrategy = .custom(AuthKeyCoding.decode)
    #expect(try a.decode(RoundTrip.self, from: json) == b.decode(RoundTrip.self, from: json))
    #expect(try b.decode(RoundTrip.self, from: json) == RoundTrip())
    let expected = ["_leading_key": "_leadingKey", "trailing_key_": "trailingKey_", "__both_x__": "__bothX__", "a_b_c": "aBC",
                    "plain": "plain", "": "", "_": "_", "x_1_y": "x1Y", "user_id": "userId", "redirect_to": "redirectTo"]
    for (snake, camel) in expected { #expect(AuthKeyCoding.fromSnakeCase(snake) == camel, "\(snake)") }
  }

  @Test func captchaUsesWireName() throws {
    let e = AuthClient.Configuration.jsonEncoder
    let s = String(decoding: try e.encode(Captcha()), as: UTF8.self)
    #expect(s.contains("\"gotrue_meta_security\""))
    #expect(!s.contains("meta_security\":{\"captcha") || s.contains("gotrue_meta_security"))
    let back = try AuthClient.Configuration.jsonDecoder.decode(Captcha.self, from: Data(s.utf8))
    #expect(back == Captcha())
  }
}

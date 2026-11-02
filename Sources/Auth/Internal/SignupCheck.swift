import ConcurrencyExtras
import Crypto
import Foundation
import HTTPTypes
import IssueReporting
import Helpers

/// The project's built-in sign-up check (fake sign-up protection): when sign-up or an e-mail/phone code answers
/// `captcha_required`, the SDK solves the proof of work (find `number` so that SHA-256(salt + number) is the challenge)
/// and sends the request once more with the answer as `stitchdb_captcha`.
enum SignupCheck {
  /// The highest number tried (the server's top difficulty).
  static let maxNumber = 1_000_000

  /// The answer to send as `stitchdb_captcha` (base64 of the challenge with `number`), or nil when the challenge is
  /// not one this SDK can solve. Runs on a background task, off the calling actor and the main thread.
  static func solve(_ challenge: JSONObject) async -> String? {
    await Task.detached(priority: .userInitiated) { solveSync(challenge) }.value
  }

  static func solveSync(_ challenge: JSONObject) -> String? {
    guard let salt = challenge["salt"]?.stringValue,
      let want = challenge["challenge"]?.stringValue?.lowercased(),
      let target = hexBytes(want), target.count == 32
    else { return nil }
    let limit = min(
      challenge["maxnumber"]?.intValue ?? challenge["maxnumber"]?.doubleValue.map { Int($0) } ?? 0, maxNumber
    )
    guard limit >= 0 else { return nil }
    let saltBytes = Array(salt.utf8)
    var buffer = saltBytes
    buffer.reserveCapacity(saltBytes.count + 8)
    for n in 0...limit {
      buffer.removeLast(buffer.count - saltBytes.count)
      buffer.append(contentsOf: String(n).utf8)
      if SHA256.hash(data: buffer).elementsEqual(target) {
        var answer = challenge
        answer["number"] = .integer(n)
        guard let data = try? JSONEncoder().encode(answer) else { return nil }
        return data.base64EncodedString()
      }
    }
    return nil
  }

  static func hexBytes(_ hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
      guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
      out.append(hi << 4 | lo)
      i += 2
    }
    return out
  }

  private static func nibble(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
    default: nil
    }
  }

  /// Whether a request is one the check guards (sign-up and e-mail/phone codes).
  static func applies(to request: Helpers.HTTPRequest) -> Bool {
    guard request.method == .post else { return false }
    let path = request.url.path
    return path.hasSuffix("/signup") || path.hasSuffix("/otp")
  }

  /// The challenge of a `captcha_required` answer: `nil` when the answer is another error, `.some(nil)` when it is
  /// `captcha_required` without a challenge (fetch one from `/challenge`).
  static func challenge(in data: Data) -> JSONObject?? {
    guard let json = try? JSONDecoder().decode(JSONObject.self, from: data) else { return nil }
    let code = json["error_code"]?.stringValue ?? json["code"]?.stringValue
    guard code == "captcha_required" else { return nil }
    return .some(json["challenge"]?.objectValue)
  }
}

/// Adds the device's language as `locale` to sign-up metadata, so the project's auth e-mails can be sent in the user's
/// language. Metadata that already has `locale`, `language` or `lang` is left as it is.
func withLocale(_ data: [String: AnyJSON]?, preferred: String? = deviceLocale()) -> [String: AnyJSON]? {
  var d = data ?? [:]
  guard d["locale"] == nil, d["language"] == nil, d["lang"] == nil, let l = preferred else { return data }
  d["locale"] = .string(l)
  return d
}

/// Test hook: the locale sent for an auth host (tests see no device locale otherwise, so request snapshots stay stable).
enum SignupLocale {
  static let overrides = LockIsolated<[String: String]>([:])

  static func value(for url: URL) -> String? {
    if let host = url.host, let o = overrides.value[host] { return o }
    return isTesting ? nil : deviceLocale()
  }
}

/// The device's preferred language as a BCP 47 tag (`de-AT`), or nil (POSIX / C locales, odd identifiers).
func deviceLocale(_ candidates: [String] = Locale.preferredLanguages + [Locale.current.identifier]) -> String? {
  for raw in candidates {
    let tag = raw.split(separator: "@").first.map(String.init)?.replacingOccurrences(of: "_", with: "-") ?? ""
    if tag.isEmpty || tag.uppercased().contains("POSIX") || tag == "C" { continue }
    if tag.range(of: "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil { return tag }
  }
  return nil
}

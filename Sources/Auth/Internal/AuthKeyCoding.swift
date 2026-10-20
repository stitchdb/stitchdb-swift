import Foundation

/// JSON key coding for auth requests and responses.
///
/// Every key is converted between camelCase and snake_case exactly like Foundation's `.convertToSnakeCase` /
/// `.convertFromSnakeCase`, except the captcha property `metaSecurity`, which the auth server reads under its
/// wire-protocol name.
enum AuthKeyCoding {
  /// Request field the auth server reads the captcha token from (wire protocol name).
  static let metaSecurityWireKey = "gotrue_meta_security"

  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
  }

  @Sendable static func encode(_ path: [any CodingKey]) -> any CodingKey {
    guard let key = path.last else { return Key(stringValue: "") }
    if key.intValue != nil { return key }
    if key.stringValue == "metaSecurity" { return Key(stringValue: metaSecurityWireKey) }
    return Key(stringValue: toSnakeCase(key.stringValue))
  }

  @Sendable static func decode(_ path: [any CodingKey]) -> any CodingKey {
    guard let key = path.last else { return Key(stringValue: "") }
    if key.intValue != nil { return key }
    if key.stringValue == metaSecurityWireKey { return Key(stringValue: "metaSecurity") }
    return Key(stringValue: fromSnakeCase(key.stringValue))
  }

  /// Port of Foundation's `JSONEncoder.KeyEncodingStrategy._convertToSnakeCase`.
  static func toSnakeCase(_ stringKey: String) -> String {
    guard !stringKey.isEmpty else { return stringKey }
    var words: [Range<String.Index>] = []
    var wordStart = stringKey.startIndex
    var searchRange = stringKey.index(after: wordStart)..<stringKey.endIndex
    while let upperCaseRange = stringKey.rangeOfCharacter(from: .uppercaseLetters, options: [], range: searchRange) {
      words.append(wordStart..<upperCaseRange.lowerBound)
      searchRange = upperCaseRange.lowerBound..<searchRange.upperBound
      guard let lowerCaseRange = stringKey.rangeOfCharacter(from: .lowercaseLetters, options: [], range: searchRange) else {
        wordStart = searchRange.lowerBound
        break
      }
      let nextCharacterAfterCapital = stringKey.index(after: upperCaseRange.lowerBound)
      if lowerCaseRange.lowerBound == nextCharacterAfterCapital {
        wordStart = upperCaseRange.lowerBound
      } else {
        let beforeLowerIndex = stringKey.index(before: lowerCaseRange.lowerBound)
        words.append(upperCaseRange.lowerBound..<beforeLowerIndex)
        wordStart = beforeLowerIndex
      }
      searchRange = lowerCaseRange.upperBound..<searchRange.upperBound
    }
    words.append(wordStart..<searchRange.upperBound)
    return words.map { stringKey[$0].lowercased() }.joined(separator: "_")
  }

  /// Port of Foundation's `JSONDecoder.KeyDecodingStrategy._convertFromSnakeCase`.
  static func fromSnakeCase(_ stringKey: String) -> String {
    guard !stringKey.isEmpty else { return stringKey }
    guard let firstNonUnderscore = stringKey.firstIndex(where: { $0 != "_" }) else { return stringKey }
    var lastNonUnderscore = stringKey.index(before: stringKey.endIndex)
    while lastNonUnderscore > firstNonUnderscore && stringKey[lastNonUnderscore] == "_" {
      stringKey.formIndex(before: &lastNonUnderscore)
    }
    let keyRange = firstNonUnderscore...lastNonUnderscore
    let leading = stringKey[stringKey.startIndex..<firstNonUnderscore]
    let trailing = stringKey[stringKey.index(after: lastNonUnderscore)..<stringKey.endIndex]
    let components = stringKey[keyRange].split(separator: "_")
    let joined = components.count == 1
      ? String(stringKey[keyRange])
      : ([components[0].lowercased()] + components[1...].map { $0.capitalized }).joined()
    return String(leading) + joined + String(trailing)
  }
}

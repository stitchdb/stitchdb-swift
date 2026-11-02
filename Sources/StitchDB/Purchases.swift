import ConcurrencyExtras
public import Foundation
import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

#if canImport(StoreKit)
  public import StoreKit
#endif

// In-app purchases (`stitchdb.purchases`, Studio › Integrations › In-app purchases): the app sends each App Store or
// Google Play purchase right after buying (and on restore); StitchDB checks it with the store, saves it for the signed-in
// user and answers with the user's entitlements. The SDK does not sell anything itself: your app keeps using StoreKit
// (or Play Billing) and passes the signed transaction it got.

/// A request to `/purchases/v1` failed: `status` is the HTTP status (401 without a signed-in user, 0 without an answer).
public struct PurchasesError: Error, LocalizedError, Sendable, Equatable, ServiceError {
  public let message: String
  public let status: Int
  public let code: String?

  public init(message: String, status: Int, code: String? = nil) {
    self.message = message
    self.status = status
    self.code = code
  }

  public var errorDescription: String? { message }
}

/// A purchase to check with its store.
public enum PurchaseInput: Encodable, Sendable, Equatable {
  /// A StoreKit 2 transaction: its `jwsRepresentation` (checked against Apple's certificates) and/or its id (with an
  /// App Store Server API key in Studio the status comes from Apple).
  case apple(signedTransaction: String?, transactionID: String? = nil)
  /// A Google Play purchase token; `productID` is needed for one-time products.
  case google(purchaseToken: String, productID: String? = nil, type: GoogleType? = nil, packageName: String? = nil)

  public enum GoogleType: String, Codable, Sendable {
    case subscription, product
  }

  enum CodingKeys: String, CodingKey {
    case store, type
    case signedTransaction = "signed_transaction"
    case transactionID = "transaction_id"
    case purchaseToken = "purchase_token"
    case productID = "product_id"
    case packageName = "package_name"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .apple(let signed, let id):
      try c.encode("apple", forKey: .store)
      try c.encodeIfPresent(signed, forKey: .signedTransaction)
      try c.encodeIfPresent(id, forKey: .transactionID)
    case .google(let token, let product, let type, let package):
      try c.encode("google", forKey: .store)
      try c.encode(token, forKey: .purchaseToken)
      try c.encodeIfPresent(product, forKey: .productID)
      try c.encodeIfPresent(type, forKey: .type)
      try c.encodeIfPresent(package, forKey: .packageName)
    }
  }
}

/// A purchase as StitchDB keeps it.
public struct Purchase: Decodable, Sendable, Equatable {
  public let id: Int
  /// `apple` or `google`.
  public let store: String
  public let productID: String
  /// `subscription` or `one_time`.
  public let kind: String
  /// `active`, `grace`, `billing_retry`, `paused`, `pending`, `expired`, `refunded` or `revoked`.
  public let status: String
  /// `production` or `sandbox`.
  public let environment: String?
  public let autoRenew: Bool?
  public let purchasedAt: String?
  public let expiresAt: String?
  public let graceUntil: String?
  public let originalID: String
  public let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, store, kind, status, environment
    case productID = "product_id"
    case autoRenew = "auto_renew"
    case purchasedAt = "purchased_at"
    case expiresAt = "expires_at"
    case graceUntil = "grace_until"
    case originalID = "original_id"
    case updatedAt = "updated_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let n = try? c.decode(Int.self, forKey: .id) { id = n } else { id = Int(try c.decode(String.self, forKey: .id)) ?? 0 }
    store = try c.decode(String.self, forKey: .store)
    productID = try c.decode(String.self, forKey: .productID)
    kind = try c.decode(String.self, forKey: .kind)
    status = try c.decode(String.self, forKey: .status)
    environment = try c.decodeIfPresent(String.self, forKey: .environment)
    autoRenew = try c.decodeIfPresent(Bool.self, forKey: .autoRenew)
    purchasedAt = try c.decodeIfPresent(String.self, forKey: .purchasedAt)
    expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    graceUntil = try c.decodeIfPresent(String.self, forKey: .graceUntil)
    originalID = try c.decodeIfPresent(String.self, forKey: .originalID) ?? ""
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  /// Whether it gives access now (active or in the grace period).
  public var isActive: Bool { status == "active" || status == "grace" }
}

/// The answer of ``PurchasesClient/sync(_:)``: the checked purchase and the user's entitlements.
public struct PurchaseSyncResult: Decodable, Sendable, Equatable {
  public let purchase: Purchase
  public let entitlements: [String]
}

/// A user's purchases (newest first) and active entitlements.
public struct PurchasesState: Decodable, Sendable, Equatable {
  public let purchases: [Purchase]
  public let entitlements: [String]
}

/// Which stores are set up for the project.
public struct PurchasesConfig: Decodable, Sendable, Equatable {
  public struct Apple: Decodable, Sendable, Equatable {
    public let bundleID: String
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id" }
  }

  public struct Google: Decodable, Sendable, Equatable {
    public let packageName: String
    enum CodingKeys: String, CodingKey { case packageName = "package_name" }
  }

  public let apple: Apple?
  public let google: Google?
}

/// In-app purchases. Use the one on ``StitchClient/purchases``.
///
/// ```swift
/// let result = try await product.purchase()
/// if case .success(let verification) = result {
///   let synced = try await stitchdb.purchases.sync(verification)   // checked by StitchDB with Apple
///   if synced.entitlements.contains("pro") { unlockPro() }
///   if case .verified(let transaction) = verification { await transaction.finish() }
/// }
/// ```
public final class PurchasesClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  let http: ServiceHTTP

  init(url: URL, headers: [String: String], fetch: Fetch? = nil) {
    http = ServiceHTTP(url: url, headers: headers, fetch: fetch)
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  /// Which stores are set up for this project.
  public func config() async throws -> PurchasesConfig {
    try await http.send("GET", ["config"], as: PurchasesConfig.self, error: PurchasesError.self)
  }

  /// Checks a purchase with the store and links it to the signed-in user. Call it after every purchase and restore.
  @discardableResult
  public func sync(_ purchase: PurchaseInput) async throws -> PurchaseSyncResult {
    try await http.send("POST", ["sync"], body: purchase, as: PurchaseSyncResult.self, error: PurchasesError.self)
  }

  /// Checks a StoreKit 2 transaction by its signed form (`jwsRepresentation`).
  @discardableResult
  public func sync(signedTransaction jws: String) async throws -> PurchaseSyncResult {
    try await sync(.apple(signedTransaction: jws))
  }

  #if canImport(StoreKit)
    /// Checks a StoreKit 2 purchase: the signed transaction of the verification result is sent (StitchDB checks the
    /// signature itself, so an unverified result is sent too and refused there if it is not genuine).
    @discardableResult
    public func sync(_ verification: VerificationResult<StoreKit.Transaction>) async throws -> PurchaseSyncResult {
      try await sync(.apple(signedTransaction: verification.jwsRepresentation))
    }
  #endif

  /// The signed-in user's purchases and active entitlements.
  public func me() async throws -> PurchasesState {
    try await http.send("GET", ["me"], as: PurchasesState.self, error: PurchasesError.self)
  }

  /// Whether the signed-in user has an entitlement (an active or in-grace purchase of one of its products).
  public func hasEntitlement(_ name: String) async throws -> Bool {
    try await me().entitlements.contains(name)
  }

  /// Server side (service key): checks a user's purchases with the stores again.
  public func refresh(userID: String) async throws -> PurchasesState {
    try await http.send(
      "POST", ["refresh"], body: ["user_id": userID], as: PurchasesState.self, error: PurchasesError.self
    )
  }
}

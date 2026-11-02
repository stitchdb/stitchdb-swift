public import Foundation
import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Usage metering per customer (`stitchdb.metering`, Studio › Integrations › Usage metering): record what each of your own
// customers uses (AI tokens, documents, minutes, seats …) and read it back per customer for billing, plan limits or a
// usage page. With the service key (server side) any customer; signed in, an app records meters marked "apps may record"
// for the user's own customer and reads its own usage.

/// A request to `/metering/v1` failed: `status` is the HTTP status (0 without an answer).
public struct MeteringError: Error, LocalizedError, Sendable, Equatable, ServiceError {
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

/// One usage event.
public struct MeterEvent: Encodable, Sendable, Equatable {
  public var meter: String
  /// How much (default 1). For a gauge meter (seats, storage) the current value.
  public var quantity: Double?
  /// Your customer's id (a user id, an organization id …). Server side only; a signed-in user records for themselves.
  public var customer: String?
  /// The same key is counted once (retries, webhooks delivered twice).
  public var idempotencyKey: String?
  /// When it happened (server side, up to 35 days back; default now).
  public var at: Date?

  public init(
    meter: String, quantity: Double? = nil, customer: String? = nil, idempotencyKey: String? = nil, at: Date? = nil
  ) {
    self.meter = meter
    self.quantity = quantity
    self.customer = customer
    self.idempotencyKey = idempotencyKey
    self.at = at
  }

  enum CodingKeys: String, CodingKey {
    case meter, quantity, customer, at
    case idempotencyKey = "idempotency_key"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(meter, forKey: .meter)
    try c.encodeIfPresent(quantity, forKey: .quantity)
    try c.encodeIfPresent(customer, forKey: .customer)
    try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    try c.encodeIfPresent(at.map(serviceIsoString), forKey: .at)
  }
}

/// How many events were counted, and how many were repeats of an idempotency key.
public struct MeterRecordResult: Decodable, Sendable, Equatable {
  public let recorded: Int
  public let duplicates: Int
}

/// How usage rows are grouped.
public enum UsageGroup: String, Codable, Sendable {
  case hour, day, month
}

/// One row of usage: a customer's value of a meter in a period.
public struct UsageRow: Decodable, Sendable, Equatable {
  public let customer: String
  public let meter: String
  public let period: String
  public let value: Double
}

/// A meter as set up in Studio.
public struct MeterInfo: Decodable, Sendable, Equatable {
  public let name: String
  public let unit: String?
  /// `sum` or `max` (gauge meters).
  public let aggregation: String
}

/// The answer of ``MeteringClient/usage(customer:meter:from:to:group:)``.
public struct UsageResult: Decodable, Sendable, Equatable {
  public let from: String
  public let to: String
  public let group: String
  public let customer: String?
  public let truncated: Bool
  public let meters: [String: MeterInfo]
  public let rows: [UsageRow]
}

/// A customer's totals per meter for a period.
public struct CustomerTotals: Decodable, Sendable, Equatable {
  public let customer: String
  public let totals: [String: Double]
}

/// The answer of ``MeteringClient/customers(from:to:meter:search:limit:offset:)``.
public struct CustomerTotalsPage: Decodable, Sendable, Equatable {
  public let customers: [CustomerTotals]
  public let total: Int
  public let sortedBy: String?

  enum CodingKeys: String, CodingKey {
    case customers, total
    case sortedBy = "sorted_by"
  }
}

private struct RecordMany: Encodable { let events: [MeterEvent] }

/// Usage metering. Use the one on ``StitchClient/metering``.
///
/// ```swift
/// // server side, with the service key: any customer
/// try await admin.metering.record("ai_tokens", quantity: 1532, customer: org.id, idempotencyKey: completion.id)
/// let usage = try await admin.metering.usage(customer: org.id, group: .month)
///
/// // in the app, signed in: meters marked "apps may record", for the user's own customer
/// try await stitchdb.metering.record("exports")
/// ```
public final class MeteringClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  let http: ServiceHTTP

  init(url: URL, headers: [String: String], fetch: Fetch? = nil) {
    http = ServiceHTTP(url: url, headers: headers, fetch: fetch)
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  /// Records usage of one meter.
  @discardableResult
  public func record(
    _ meter: String, quantity: Double = 1, customer: String? = nil, idempotencyKey: String? = nil, at: Date? = nil
  ) async throws -> MeterRecordResult {
    let event = MeterEvent(meter: meter, quantity: quantity, customer: customer, idempotencyKey: idempotencyKey, at: at)
    return try await http.send("POST", ["record"], body: event, as: MeterRecordResult.self, error: MeteringError.self)
  }

  /// Records up to 1,000 events in one request.
  @discardableResult
  public func recordMany(_ events: [MeterEvent]) async throws -> MeterRecordResult {
    try await http.send(
      "POST", ["record"], body: RecordMany(events: events), as: MeterRecordResult.self, error: MeteringError.self
    )
  }

  /// Usage per customer, meter and period (the sum for sum meters, the highest value for gauge meters). Default: the
  /// last 30 days, per day. A signed-in user always reads their own.
  public func usage(
    customer: String? = nil, meter: String? = nil, from: Date? = nil, to: Date? = nil, group: UsageGroup? = nil
  ) async throws -> UsageResult {
    let query = queryItems([
      ("customer", customer), ("meter", meter), ("from", from.map(serviceIsoString)), ("to", to.map(serviceIsoString)),
      ("group", group?.rawValue),
    ])
    return try await http.send("GET", ["usage"], query: query, as: UsageResult.self, error: MeteringError.self)
  }

  /// Totals per customer for a period, largest first (service key).
  public func customers(
    from: Date? = nil, to: Date? = nil, meter: String? = nil, search: String? = nil, limit: Int? = nil,
    offset: Int? = nil
  ) async throws -> CustomerTotalsPage {
    let query = queryItems([
      ("from", from.map(serviceIsoString)), ("to", to.map(serviceIsoString)), ("meter", meter),
      ("search", search.flatMap { $0.isEmpty ? nil : $0 }), ("limit", limit.map(String.init)),
      ("offset", offset.map(String.init)),
    ])
    return try await http.send(
      "GET", ["customers"], query: query, as: CustomerTotalsPage.self, error: MeteringError.self
    )
  }

  /// Every row of a period as CSV text (`customer,meter,period,value`), for your billing system (service key).
  public func exportCSV(
    meter: String? = nil, from: Date? = nil, to: Date? = nil, group: UsageGroup? = nil
  ) async throws -> String {
    let query = queryItems([
      ("meter", meter), ("from", from.map(serviceIsoString)), ("to", to.map(serviceIsoString)),
      ("group", group?.rawValue), ("format", "csv"),
    ])
    let (data, _) = try await http.raw("GET", ["export"], query: query, error: MeteringError.self)
    return String(decoding: data, as: UTF8.self)
  }
}

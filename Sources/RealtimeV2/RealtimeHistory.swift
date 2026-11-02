import ConcurrencyExtras
public import Foundation
import HTTPTypes
import Helpers

// Message history for broadcast channels (Studio › Realtime › Message history): with
// `config.history = RealtimeHistoryConfig()` the broadcasts a client missed while it was offline are fetched from
// `/history/v1/messages` after every (re)join and delivered first, in order, then the live ones that arrived meanwhile.
// Ids already delivered are skipped. Replayed messages carry `meta: { id, replayed: true }`.

/// Turns on message history for a channel.
public struct RealtimeHistoryConfig: Sendable {
  /// Also replay what was published since this time on the first join (default: only what is missed after joining).
  public var since: Date?
  /// Called when fetching missed messages fails (live messages keep coming).
  public var onError: (@Sendable (any Error) -> Void)?

  public init(since: Date? = nil, onError: (@Sendable (any Error) -> Void)? = nil) {
    self.since = since
    self.onError = onError
  }
}

/// A message stored by ``RealtimeChannelV2/publish(event:payload:)``.
public struct RealtimeHistoryMessage: Decodable, Sendable, Equatable {
  public let id: String
  public let insertedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case insertedAt = "inserted_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if let n = try? c.decode(Int.self, forKey: .id) { id = String(n) } else { id = try c.decode(String.self, forKey: .id) }
    insertedAt = try c.decodeIfPresent(String.self, forKey: .insertedAt)
  }
}

final class RealtimeHistory: Sendable {
  static let seenMax = 2000

  struct State {
    var seen: Set<String> = []
    var order: [String] = []
    var last: String?
    var since: Date?
    var catching = false
    var again = false
    var buffer: [(String, JSONObject)] = []
  }

  let topic: String
  let isPrivate: Bool
  let url: URL
  let enabled: Bool
  let onError: (@Sendable (any Error) -> Void)?
  let http: any HTTPClientType
  let headers: @Sendable () async -> HTTPFields
  let deliver: @Sendable (_ event: String, _ payload: JSONObject) -> Void
  let state = LockIsolated(State())

  init(
    topic: String, isPrivate: Bool, url: URL, config: RealtimeHistoryConfig?, http: any HTTPClientType,
    headers: @escaping @Sendable () async -> HTTPFields,
    deliver: @escaping @Sendable (_ event: String, _ payload: JSONObject) -> Void
  ) {
    self.topic = topic
    self.isPrivate = isPrivate
    self.url = url
    self.enabled = config != nil
    self.onError = config?.onError
    self.http = http
    self.headers = headers
    self.deliver = deliver
    state.withValue { $0.since = config?.since }
  }

  private static func mark(_ id: String, _ s: inout State) {
    guard s.seen.insert(id).inserted else { return }
    s.order.append(id)
    if s.order.count > seenMax { s.seen.remove(s.order.removeFirst()) }
  }

  private func send(_ event: String, _ payload: JSONObject) {
    if let id = payload["meta"]?.objectValue?["id"]?.stringValue { state.withValue { $0.last = id } }
    deliver(event, payload)
  }

  /// A live broadcast (`payload` is `{ type, event, payload, meta? }`).
  func live(event: String, payload: JSONObject) {
    let id = payload["meta"]?.objectValue?["id"]?.stringValue
    let deliverNow = state.withValue { s -> Bool? in
      if let id {
        if s.seen.contains(id) { return nil }
        Self.mark(id, &s)
      }
      if s.catching {
        s.buffer.append((event, payload))
        return false
      }
      return true
    }
    if deliverNow == true { send(event, payload) }
  }

  /// Fetches and delivers what was missed (after every join).
  func catchUp() async {
    let start = state.withValue { s -> Bool in
      if s.catching {
        s.again = true
        return false
      }
      if s.last == nil && s.since == nil { return false }
      s.catching = true
      return true
    }
    guard start else { return }
    do {
      for _ in 0..<50 {
        let (last, since) = state.withValue { ($0.last, $0.since) }
        var query = [
          URLQueryItem(name: "topic", value: topic), URLQueryItem(name: "private", value: String(isPrivate)),
          URLQueryItem(name: "limit", value: "200"),
        ]
        if let last {
          query.append(URLQueryItem(name: "after", value: last))
        } else if let since {
          query.append(URLQueryItem(name: "since", value: String(Int64(since.timeIntervalSince1970 * 1000))))
        }
        let response = try await http.send(
          HTTPRequest(
            url: url.appendingPathComponent("messages"), method: .get, query: query, headers: await headers()
          )
        )
        let body = (try? JSONDecoder().decode(JSONObject.self, from: response.data)) ?? [:]
        guard (200..<300).contains(response.statusCode) else {
          throw RealtimeError(body["message"]?.stringValue ?? "Message history: HTTP \(response.statusCode)")
        }
        for row in body["messages"]?.arrayValue ?? [] {
          guard let r = row.objectValue, let id = r["id"]?.stringValue ?? r["id"]?.intValue.map(String.init) else {
            continue
          }
          let isNew = state.withValue { s -> Bool in
            if s.seen.contains(id) {
              s.last = id
              return false
            }
            Self.mark(id, &s)
            return true
          }
          guard isNew else { continue }
          let event = r["event"]?.stringValue ?? ""
          send(
            event,
            [
              "type": "broadcast", "event": .string(event), "payload": r["payload"] ?? .null,
              "meta": ["id": .string(id), "replayed": true],
            ]
          )
        }
        state.withValue { $0.since = nil }
        if body["more"]?.boolValue != true { break }
      }
    } catch {
      onError?(error)
    }
    let (buffered, again) = state.withValue { s -> ([(String, JSONObject)], Bool) in
      defer {
        s.buffer = []
        s.catching = false
        s.again = false
      }
      return (s.buffer, s.again)
    }
    for (event, payload) in buffered { deliver(event, payload) }
    if again { await catchUp() }
  }

  /// Stores a message in the history and broadcasts it to the channel.
  func publish(event: String, payload: JSONObject) async throws -> RealtimeHistoryMessage {
    var headers = await headers()
    headers[.contentType] = "application/json"
    let body = try JSONEncoder().encode(
      [
        "topic": .string(topic), "event": .string(event), "payload": .object(payload), "private": .bool(isPrivate),
      ] as JSONObject
    )
    let response = try await http.send(
      HTTPRequest(url: url.appendingPathComponent("messages"), method: .post, headers: headers, body: body)
    )
    guard (200..<300).contains(response.statusCode) else {
      let json = try? JSONDecoder().decode(JSONObject.self, from: response.data)
      throw RealtimeError(json?["message"]?.stringValue ?? "publish: HTTP \(response.statusCode)")
    }
    return try JSONDecoder().decode(RealtimeHistoryMessage.self, from: response.data)
  }
}

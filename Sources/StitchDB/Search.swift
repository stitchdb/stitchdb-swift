public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Search (`stitchdb.search(table, query)`, Studio › Database › Search): keyword, semantic or hybrid search over a table
// that has a search index, with the caller's row level security (the rows a user may read, like the REST API).

/// A search failed: `status` is the HTTP status (404 for a table without a search index, 0 without an answer).
public struct SearchError: Error, LocalizedError, Sendable, Equatable, ServiceError {
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

/// How to search.
public enum SearchMode: String, Codable, Sendable {
  /// Words and meaning (the default for semantic indexes).
  case hybrid
  case keyword
  case semantic
}

/// The options of a search.
public struct SearchOptions: Encodable, Sendable, Equatable {
  /// 1 to 100 results (default 20).
  public var limit: Int?
  public var mode: SearchMode?
  /// Columns to return, for example `id,title` (default all).
  public var select: String?

  public init(limit: Int? = nil, mode: SearchMode? = nil, select: String? = nil) {
    self.limit = limit
    self.mode = mode
    self.select = select
  }
}

/// How well a row matched.
public struct SearchScore: Decodable, Sendable, Equatable {
  public let score: Double
  public let keywordRank: Int?
  public let semanticRank: Int?

  enum CodingKeys: String, CodingKey {
    case score
    case keywordRank = "keyword_rank"
    case semanticRank = "semantic_rank"
  }
}

/// The rows found, best first, with their scores (same order).
public struct SearchResults<Row: Decodable & Sendable>: Decodable, Sendable {
  public let data: [Row]
  public let scores: [SearchScore]
  /// The mode that was used.
  public let mode: SearchMode
  /// Set when the search fell back to another mode (for example keyword while embeddings are being made).
  public let note: String?
}

private struct SearchBody: Encodable {
  let q: String
  let limit: Int?
  let mode: SearchMode?
  let select: String?
}

/// Search over the project's tables. Use ``StitchClient/search(_:_:options:as:)``.
public final class SearchClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  let http: ServiceHTTP

  init(url: URL, headers: [String: String], fetch: Fetch? = nil) {
    http = ServiceHTTP(url: url, headers: headers, fetch: fetch)
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  /// Searches `table` for `query`; rows are decoded as `Row`.
  public func search<Row: Decodable & Sendable>(
    _ table: String, _ query: String, options: SearchOptions = SearchOptions(), as: Row.Type = JSONObject.self
  ) async throws -> SearchResults<Row> {
    let body = SearchBody(q: query, limit: options.limit, mode: options.mode, select: options.select)
    return try await http.send("POST", [table], body: body, as: SearchResults<Row>.self, error: SearchError.self)
  }
}

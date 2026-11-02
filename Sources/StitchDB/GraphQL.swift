public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// The GraphQL API (`stitchdb.graphql(...)`, Studio › API › GraphQL): queries and mutations over the project's tables at
// `/graphql/v1`. The same API keys and row level security as the REST API apply: signed in, the query runs as the user.

/// One entry of a GraphQL answer's `errors`.
public struct GraphQLErrorItem: Codable, Sendable, Equatable {
  public struct Location: Codable, Sendable, Equatable {
    public let line: Int
    public let column: Int
  }

  public let message: String
  public let locations: [Location]?
  /// Field names and list indexes.
  public let path: [AnyJSON]?
  public let extensions: JSONObject?
}

/// The request failed (network, HTTP status, API turned off) or the answer has GraphQL errors.
public struct GraphQLError: Error, LocalizedError, Sendable, Equatable {
  public let message: String
  /// The HTTP status (0 without an answer).
  public let status: Int
  public let errors: [GraphQLErrorItem]

  public init(message: String, status: Int, errors: [GraphQLErrorItem] = []) {
    self.message = message
    self.status = status
    self.errors = errors
  }

  public var errorDescription: String? { message }
}

/// What the server answered: `data` can be partial when some fields failed; `error` is set when the request failed or
/// the answer has errors.
public struct GraphQLResponse: Sendable, Equatable {
  public let data: AnyJSON?
  public let errors: [GraphQLErrorItem]?
  public let error: GraphQLError?

  /// `data` decoded as `T` (nil without data).
  public func decode<T: Decodable>(as: T.Type = T.self) throws -> T? {
    guard let data, data != .null else { return nil }
    return try data.decode(as: T.self)
  }
}

private struct GraphQLBody: Encodable {
  let query: String
  let variables: JSONObject
  let operationName: String?
}

private struct GraphQLAnswer: Decodable {
  let data: AnyJSON?
  let errors: [GraphQLErrorItem]?
  let message: String?
}

func graphqlRequest(
  url: URL, fetch: CrashesClient.Fetch, headers: [String: String], query: String, variables: JSONObject,
  operationName: String?, extraHeaders: [String: String]
) async -> GraphQLResponse {
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue("application/json", forHTTPHeaderField: "Accept")
  for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
  do {
    request.httpBody = try JSONEncoder().encode(
      GraphQLBody(query: query, variables: variables, operationName: operationName)
    )
    let (data, response) = try await fetch(request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let answer = try? JSONDecoder().decode(GraphQLAnswer.self, from: data)
    let errors = answer?.errors.flatMap { $0.isEmpty ? nil : $0 }
    guard (200..<300).contains(status) else {
      let message =
        answer?.message ?? errors?.first?.message
        ?? (status == 404
          ? "The GraphQL API is not turned on for this project (Studio › API › GraphQL)" : "Request failed (\(status))")
      return GraphQLResponse(
        data: answer?.data, errors: errors,
        error: GraphQLError(message: message, status: status, errors: errors ?? [])
      )
    }
    return GraphQLResponse(
      data: answer?.data, errors: errors,
      error: errors.map { GraphQLError(message: $0.first?.message ?? "GraphQL error", status: status, errors: $0) }
    )
  } catch {
    return GraphQLResponse(data: nil, errors: nil, error: GraphQLError(message: error.localizedDescription, status: 0))
  }
}

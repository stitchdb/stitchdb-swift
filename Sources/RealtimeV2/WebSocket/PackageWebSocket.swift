package import Foundation

#if canImport(FoundationNetworking)
  package import FoundationNetworking
#endif

/// What a ``StitchWebSocketConnection`` receives.
package enum StitchWebSocketEvent: Sendable, Equatable {
  case text(String)
  case binary(Data)
  case close(code: Int?, reason: String)
}

/// A WebSocket for the other StitchDB modules (collaborative documents, SQL sessions), on the same `URLSession` based
/// implementation Realtime uses. Tests pass their own.
package protocol StitchWebSocketConnection: AnyObject, Sendable {
  func send(_ text: String)
  func close(code: Int?, reason: String?)
  /// Ends with the connection.
  var events: AsyncStream<StitchWebSocketEvent> { get }
}

/// Opens a connection to a `ws:` / `wss:` URL with the given upgrade request headers.
package typealias StitchWebSocketConnect =
  @Sendable (_ url: URL, _ headers: [String: String]) async throws -> any StitchWebSocketConnection

/// The default ``StitchWebSocketConnect``: `URLSessionWebSocketTask` (with `session`'s configuration and delegate).
package func stitchWebSocketConnect(session: URLSession? = nil) -> StitchWebSocketConnect {
  { [session] url, headers in
    let socket = try await URLSessionWebSocket.connect(to: url, headers: headers, session: session)
    return URLSessionStitchWebSocket(socket)
  }
}

private final class URLSessionStitchWebSocket: StitchWebSocketConnection {
  let socket: URLSessionWebSocket
  let events: AsyncStream<StitchWebSocketEvent>

  init(_ socket: URLSessionWebSocket) {
    self.socket = socket
    let source = socket.events
    events = AsyncStream { continuation in
      let task = Task {
        for await event in source {
          switch event {
          case .text(let text): continuation.yield(.text(text))
          case .binary(let data): continuation.yield(.binary(data))
          case .close(let code, let reason): continuation.yield(.close(code: code, reason: reason))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func send(_ text: String) { socket.send(text) }

  func close(code: Int?, reason: String?) { socket.close(code: code, reason: reason) }
}

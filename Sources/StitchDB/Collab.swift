import ConcurrencyExtras
public import Foundation
public import Helpers
import RealtimeV2

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Collaborative documents (`stitchdb.collab(yjs:)`, Studio › Realtime › Collaborative docs): keep a Yjs document in sync
// between everyone who has it open, stored in the project with history. Who may open and edit a document is row level
// security on `collab.documents` (by default the creator owns it and shares it as viewer or editor).
//
// The wire protocol carries Yjs updates as opaque bytes (base64), so this SDK has no CRDT of its own: plug any Yjs port
// (for example bindings to the y-crdt / yrs Rust library) in through ``CollabYjs`` and ``CollabDocument``. One
// WebSocket (`wss://<ref>.p.stitchdb.com/collab/v1/ws`) serves every open document; changes made offline are kept and
// sent when the connection is back.

/// The parts of a Yjs implementation the provider needs (like the `yjs` module in JavaScript).
public protocol CollabYjs: Sendable {
  /// Merges several updates into one (`Y.mergeUpdates`).
  func mergeUpdates(_ updates: [Data]) -> Data
  /// A new, empty document (for ``CollabRoom/loadSnapshot(_:)``).
  func makeDocument() -> any CollabDocument
}

/// A Yjs document (a `Y.Doc`), as the provider uses it.
public protocol CollabDocument: AnyObject, Sendable {
  /// Applies an update that came from the server (`Y.applyUpdate`).
  func applyUpdate(_ update: Data)
  /// The whole document as one update (`Y.encodeStateAsUpdate`).
  func encodeStateAsUpdate() -> Data
  /// Calls `handler` with every update of the document (`doc.on('update')`) until the returned function is called.
  /// Updates reported while ``applyUpdate(_:)`` runs are taken as remote and not sent back.
  func observeUpdates(_ handler: @escaping @Sendable (Data) -> Void) -> @Sendable () -> Void
}

/// The connection state.
public enum CollabStatus: String, Sendable {
  case connecting, connected, offline
}

/// A collaborative documents request or connection failed. `code` is `forbidden`, `not_found`, `unauthorized`,
/// `rate_limited`, `too_many_connections`, `http_<status>` or another code of the server.
public struct CollabError: Error, LocalizedError, Sendable, Equatable, ServiceError {
  public let message: String
  public let code: String
  public let status: Int

  public init(message: String, code: String, status: Int = 0) {
    self.message = message
    self.code = code
    self.status = status
  }

  init(message: String, status: Int, code: String?) {
    self.message = message
    self.status = status
    self.code =
      code.flatMap { Int($0) == nil ? $0 : nil }
      ?? (status == 403 ? "forbidden" : status == 404 ? "not_found" : "http_\(status)")
  }

  public var errorDescription: String? { message }
}

/// A document the signed-in user can open.
public struct CollabDocumentInfo: Decodable, Sendable, Equatable {
  public let id: String
  public let title: String?
  public let ownerID: String?
  public let orgID: String?
  public let metadata: JSONObject
  public let sizeBytes: Int
  public let createdAt: String?
  public let updatedAt: String?
  /// `owner`, `editor`, `viewer`, or nil when another policy lets the user in.
  public let access: String?

  enum CodingKeys: String, CodingKey {
    case id, title, metadata, access
    case ownerID = "owner_id"
    case orgID = "org_id"
    case sizeBytes = "size_bytes"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
    orgID = try c.decodeIfPresent(String.self, forKey: .orgID)
    metadata = try c.decodeIfPresent(JSONObject.self, forKey: .metadata) ?? [:]
    sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes) ?? 0
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    access = try c.decodeIfPresent(String.self, forKey: .access)
  }
}

/// Someone a document is shared with.
public struct CollabMember: Decodable, Sendable, Equatable {
  public let userID: String
  /// `viewer` or `editor`.
  public let role: String
  public let createdAt: String?

  enum CodingKeys: String, CodingKey {
    case role
    case userID = "user_id"
    case createdAt = "created_at"
  }
}

/// A saved state of a document.
public struct CollabSnapshotInfo: Decodable, Sendable, Equatable {
  public let id: Int
  public let seq: Int
  public let sizeBytes: Int
  public let label: String?
  public let auto: Bool
  public let createdAt: String?

  enum CodingKeys: String, CodingKey {
    case id, seq, label, auto
    case sizeBytes = "size_bytes"
    case createdAt = "created_at"
  }
}

private struct DocList: Decodable { let documents: [CollabDocumentInfo] }
private struct MemberList: Decodable { let members: [CollabMember] }
private struct SnapshotList: Decodable { let snapshots: [CollabSnapshotInfo] }
private struct SnapshotID: Decodable { let id: Int }
private struct SnapshotUpdates: Decodable { let updates: [String] }
private struct Ignored: Decodable {}

/// One open document. Get it from ``CollabClient/open(_:document:create:title:)``.
public final class CollabRoom: Sendable {
  struct State {
    var write = false
    var synced = false
    var joined = false
    var seq = 0
    var pending: [Data] = []
    var inflight: [Int: Data] = [:]
    var presence: JSONObject?
    var peers: [String: JSONObject] = [:]
    var applying = 0
    var ready: CheckedContinuation<Void, any Error>?
    var stopObserving: (@Sendable () -> Void)?
    var handlers: [Int: Handler] = [:]
    var nextHandler = 0
  }

  enum Handler {
    case presence(@Sendable ([String: JSONObject]) -> Void)
    case synced(@Sendable (Bool) -> Void)
    case status(@Sendable (CollabStatus) -> Void)
    case error(@Sendable (CollabError) -> Void)
  }

  public let id: String
  public let document: any CollabDocument
  let create: JSONObject?
  let state = LockIsolated(State())
  private let clientRef: WeakCollabClient
  private var client: CollabClient? { clientRef.value }

  init(client: CollabClient, id: String, document: any CollabDocument, create: JSONObject?) {
    self.clientRef = WeakCollabClient(client)
    self.id = id
    self.document = document
    self.create = create
    let stop = document.observeUpdates { [weak self] update in
      guard let self else { return }
      let local = self.state.withValue { s -> Bool in
        guard s.applying == 0 else { return false }
        s.pending.append(update)
        return true
      }
      if local { self.client?.flush(self) }
    }
    state.withValue { $0.stopObserving = stop }
  }

  /// True when the signed-in user may edit (your UPDATE policy on `collab.documents`); otherwise edits stay local.
  public var canWrite: Bool { state.write }
  /// True once the stored document has been loaded into the document.
  public var isSynced: Bool { state.synced }
  /// The others in the document with their presence state, by connection id.
  public var peers: [String: JSONObject] { state.peers }
  /// Changes not saved on the server yet (made offline, or waiting for the answer).
  public var unsaved: Int { state.withValue { $0.pending.count + $0.inflight.count } }

  /// Your cursor, selection, name or colour, shown to the others. Nil hides you.
  public func setPresence(_ presence: JSONObject?) {
    state.withValue { $0.presence = presence }
    client?.send(["t": "presence", "doc": .string(id), "state": presence.map(AnyJSON.object) ?? .null], room: self)
  }

  /// Saves the document as it is now in its history; returns the snapshot id.
  @discardableResult
  public func snapshot(label: String? = nil) async throws -> Int {
    guard let client else { throw CollabError(message: "The client is closed", code: "closed") }
    var body: JSONObject = [:]
    if let label { body["label"] = .string(label) }
    return try await client.http.send(
      "POST", ["docs", id, "snapshots"], body: body, as: SnapshotID.self, error: CollabError.self
    ).id
  }

  /// The document's history, newest first (automatic hourly snapshots and the ones you took).
  public func snapshots() async throws -> [CollabSnapshotInfo] {
    guard let client else { throw CollabError(message: "The client is closed", code: "closed") }
    return try await client.http.send("GET", ["docs", id, "snapshots"], as: SnapshotList.self, error: CollabError.self)
      .snapshots
  }

  /// A snapshot as a new, separate document (to read it, show a diff, or copy parts back).
  public func loadSnapshot(_ snapshot: Int) async throws -> any CollabDocument {
    guard let client else { throw CollabError(message: "The client is closed", code: "closed") }
    let answer = try await client.http.send(
      "GET", ["docs", id, "snapshots", String(snapshot)], as: SnapshotUpdates.self, error: CollabError.self
    )
    let doc = client.yjs.makeDocument()
    for update in answer.updates { if let data = Data(base64Encoded: update) { doc.applyUpdate(data) } }
    return doc
  }

  /// Stops syncing this document (the document keeps its content).
  public func close() {
    let stop = state.withValue { s -> (@Sendable () -> Void)? in
      defer { s.stopObserving = nil }
      return s.stopObserving
    }
    stop?()
    client?.leave(self)
  }

  /// Called with the peers whenever someone joins, leaves or changes their presence.
  public func onPresence(_ handler: @escaping @Sendable ([String: JSONObject]) -> Void) -> ObservationToken {
    add(.presence(handler))
  }

  /// Called when the stored document has been loaded (again after every reconnect).
  public func onSynced(_ handler: @escaping @Sendable (Bool) -> Void) -> ObservationToken { add(.synced(handler)) }

  /// Called when the connection state changes.
  public func onStatus(_ handler: @escaping @Sendable (CollabStatus) -> Void) -> ObservationToken {
    add(.status(handler))
  }

  /// Called with errors after the document opened (a refused edit, the access taken away, …).
  public func onError(_ handler: @escaping @Sendable (CollabError) -> Void) -> ObservationToken { add(.error(handler)) }

  private func add(_ handler: Handler) -> ObservationToken {
    let key = state.withValue { s -> Int in
      s.nextHandler += 1
      s.handlers[s.nextHandler] = handler
      return s.nextHandler
    }
    return ObservationToken { [weak self] in self?.state.withValue { _ = $0.handlers.removeValue(forKey: key) } }
  }

  func emitPresence() {
    let (peers, handlers) = state.withValue { ($0.peers, Array($0.handlers.values)) }
    for case .presence(let h) in handlers { h(peers) }
  }

  func emitSynced() {
    for case .synced(let h) in state.withValue({ Array($0.handlers.values) }) { h(true) }
  }

  func emitStatus(_ status: CollabStatus) {
    for case .status(let h) in state.withValue({ Array($0.handlers.values) }) { h(status) }
  }

  func emitError(_ error: CollabError) {
    for case .error(let h) in state.withValue({ Array($0.handlers.values) }) { h(error) }
  }

  /// Applies a server update without sending it back.
  func apply(_ base64: String) {
    guard let data = Data(base64Encoded: base64) else { return }
    state.withValue { $0.applying += 1 }
    document.applyUpdate(data)
    state.withValue { $0.applying -= 1 }
  }

  /// Fails ``CollabClient/open(_:document:create:title:)`` while it waits, else reports the error.
  func fail(_ error: CollabError) {
    let waiting = state.withValue { s -> CheckedContinuation<Void, any Error>? in
      defer { s.ready = nil }
      return s.ready
    }
    if let waiting {
      let stop = state.withValue { s -> (@Sendable () -> Void)? in
        defer { s.stopObserving = nil }
        return s.stopObserving
      }
      stop?()
      waiting.resume(throwing: error)
    } else {
      emitError(error)
    }
  }
}

/// The connection for collaborative documents (one WebSocket for every open document). Make it with
/// ``StitchClient/collab(yjs:compactAfter:)``.
///
/// ```swift
/// let collab = stitchdb.collab(yjs: MyYrsAdapter())
/// let doc = MyYrsDocument()
/// let room = try await collab.open("plan-2026", document: doc, create: true, title: "Plan 2026")
/// room.setPresence(["name": "Ann", "cursor": 4])
/// let token = room.onPresence { peers in drawCursors(peers) }
/// ```
public final class CollabClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  struct State {
    var status: CollabStatus = .offline
    var rooms: [String: CollabRoom] = [:]
    var socket: (any StitchWebSocketConnection)?
    var generation = 0
    var ready = false
    var closed = false
    var retry = 0
    var nextID = 1
    var reconnect: Task<Void, Never>?
    var refresh: Task<Void, Never>?
    var reader: Task<Void, Never>?
  }

  let yjs: any CollabYjs
  let compactAfter: Int
  let http: ServiceHTTP
  private let wsURL: URL
  private let apikey: String
  private let getToken: @Sendable () async -> String?
  private let connectSocket: StitchWebSocketConnect
  private let state = LockIsolated(State())

  init(
    wsURL: URL, http: ServiceHTTP, apikey: String, getToken: @escaping @Sendable () async -> String?,
    connect: @escaping StitchWebSocketConnect, yjs: any CollabYjs, compactAfter: Int = 200
  ) {
    self.wsURL = wsURL
    self.http = http
    self.apikey = apikey
    self.getToken = getToken
    self.connectSocket = connect
    self.yjs = yjs
    self.compactAfter = compactAfter
  }

  deinit {
    let s = state.value
    s.reconnect?.cancel()
    s.refresh?.cancel()
    s.reader?.cancel()
    s.socket?.close(code: 1000, reason: nil)
  }

  /// The connection state.
  public var status: CollabStatus { state.status }

  /// Opens a document and loads it into `document`; returns once the stored content is in.
  ///
  /// - Parameters:
  ///   - create: Creates the document if it does not exist yet (your INSERT policy on `collab.documents` decides who
  ///     may), with `title`.
  public func open(_ id: String, document: any CollabDocument, create: Bool = false, title: String? = nil) async throws
    -> CollabRoom
  {
    var createBody: JSONObject?
    if create {
      createBody = [:]
      if let title { createBody?["title"] = .string(title) }
    }
    let room = CollabRoom(client: self, id: id, document: document, create: createBody)
    let (taken, ready) = state.withValue { s -> (Bool, Bool) in
      if s.rooms[id] != nil { return (true, false) }
      s.rooms[id] = room
      return (false, s.ready)
    }
    if taken {
      room.close()
      throw CollabError(message: "\(id) is already open", code: "already_open")
    }
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        room.state.withValue { $0.ready = continuation }
        if ready { join(room) } else { connect() }
      }
    } catch {
      state.withValue { s in if s.rooms[id] === room { s.rooms[id] = nil } }
      throw error
    }
    return room
  }

  /// The documents the signed-in user can open, most recently edited first.
  public func list(limit: Int = 50) async throws -> [CollabDocumentInfo] {
    try await http.send(
      "GET", ["docs"], query: [URLQueryItem(name: "limit", value: String(limit))], as: DocList.self,
      error: CollabError.self
    ).documents
  }

  /// Who a document is shared with.
  public func members(_ id: String) async throws -> [CollabMember] {
    try await http.send("GET", ["docs", id, "members"], as: MemberList.self, error: CollabError.self).members
  }

  /// Shares a document with a user as `viewer` or `editor` (by default only its owner may); changes the role if it is
  /// shared already.
  public func share(_ id: String, userID: String, role: String = "editor") async throws {
    _ = try await http.send(
      "POST", ["docs", id, "members"], body: ["user_id": userID, "role": role], as: Ignored.self,
      error: CollabError.self
    )
  }

  /// Stops sharing a document with a user (the owner, or the user leaving it).
  public func unshare(_ id: String, userID: String) async throws {
    _ = try await http.send("DELETE", ["docs", id, "members", userID], as: Ignored.self, error: CollabError.self)
  }

  /// Closes every document and the connection.
  public func close() {
    let rooms = state.withValue { s -> [CollabRoom] in
      s.closed = true
      s.reconnect?.cancel()
      s.refresh?.cancel()
      return Array(s.rooms.values)
    }
    for room in rooms { room.close() }
    let socket = state.withValue { s -> (any StitchWebSocketConnection)? in
      defer {
        s.socket = nil
        s.ready = false
      }
      return s.socket
    }
    socket?.close(code: 1000, reason: nil)
  }

  // MARK: Connection

  private func setStatus(_ status: CollabStatus) {
    let rooms = state.withValue { s -> [CollabRoom]? in
      if s.status == status { return nil }
      s.status = status
      return Array(s.rooms.values)
    }
    for room in rooms ?? [] { room.emitStatus(status) }
  }

  private func token() async -> String? {
    let t = await getToken()
    return t == apikey ? nil : t
  }

  private func connect() {
    let generation = state.withValue { s -> Int? in
      if s.socket != nil || s.closed || s.reader != nil { return nil }
      s.generation += 1
      return s.generation
    }
    guard let generation else { return }
    setStatus(.connecting)
    let task = Task { [weak self, connectSocket, wsURL] in
      do {
        let socket = try await connectSocket(wsURL, [:])
        guard let self else { return }
        self.state.withValue {
          $0.socket = socket
          $0.retry = 0
        }
        let token = await self.token()
        socket.send(Self.encode(["t": "auth", "apikey": .string(self.apikey), "token": token.map(AnyJSON.string) ?? .null]))
        var closeCode: Int?
        var closeReason = ""
        for await event in socket.events {
          switch event {
          case .text(let text): self.message(text)
          case .binary(let data): self.message(String(decoding: data, as: UTF8.self))
          case .close(let code, let reason):
            closeCode = code
            closeReason = reason
          }
        }
        self.closed(generation: generation, code: closeCode, reason: closeReason)
      } catch {
        self?.closed(generation: generation, code: nil, reason: error.localizedDescription)
      }
    }
    state.withValue { $0.reader = task }
  }

  private func closed(generation: Int, code: Int?, reason: String) {
    let rooms = state.withValue { s -> [CollabRoom]? in
      guard s.generation == generation else { return nil }
      s.socket = nil
      s.reader = nil
      s.ready = false
      s.refresh?.cancel()
      s.refresh = nil
      return Array(s.rooms.values)
    }
    guard let rooms else { return }
    for room in rooms {
      room.state.withValue {
        $0.joined = false
        $0.peers = [:]
      }
      room.emitPresence()
    }
    setStatus(.offline)
    let (stop, attempt) = state.withValue { s -> (Bool, Int) in
      let stop = s.closed || s.rooms.isEmpty
      defer { if !stop { s.retry += 1 } }
      return (stop, s.retry)
    }
    if stop { return }
    if code == 4029 {
      for room in rooms {
        room.fail(CollabError(message: reason.isEmpty ? "Too many connections" : reason, code: "too_many_connections"))
      }
    }
    let wait = min(30.0, 0.5 * pow(2.0, Double(attempt))) * Double.random(in: 0.5...1.0)
    let task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.connect()
    }
    state.withValue { $0.reconnect = task }
  }

  private func join(_ room: CollabRoom) {
    let since = room.state.withValue { $0.synced ? $0.seq : 0 }
    var message: JSONObject = ["t": "join", "doc": .string(room.id), "since": .integer(since)]
    if let create = room.create { message["create"] = .object(create) }
    send(message, room: nil)
  }

  private func message(_ text: String) {
    guard let m = try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8)), let t = m["t"]?.stringValue else {
      return
    }
    let room = m["doc"]?.stringValue.flatMap { id in state.withValue { $0.rooms[id] } }
    switch t {
    case "ready":
      let rooms = state.withValue { s -> [CollabRoom] in
        s.ready = true
        return Array(s.rooms.values)
      }
      setStatus(.connected)
      for r in rooms { join(r) }
      scheduleTokenRefresh()
    case "joined":
      if let room { joined(room, m) }
    case "update":
      if let room, let data = m["data"]?.stringValue {
        room.apply(data)
        let seq = m["seq"]?.intValue ?? 0
        room.state.withValue { $0.seq = max($0.seq, seq) }
      }
    case "ack":
      if let room {
        let id = m["id"]?.intValue ?? -1
        let seq = m["seq"]?.intValue ?? 0
        room.state.withValue {
          $0.inflight[id] = nil
          $0.seq = max($0.seq, seq)
        }
      }
    case "presence":
      if let room, let client = m["client"]?.stringValue {
        room.state.withValue { $0.peers[client] = m["state"]?.objectValue }
        room.emitPresence()
      }
    case "left":
      if let room, let reason = m["reason"]?.stringValue {
        room.state.withValue { $0.joined = false }
        state.withValue { s in if s.rooms[room.id] === room { s.rooms[room.id] = nil } }
        room.emitError(CollabError(message: reason, code: "forbidden"))
      }
    case "error":
      let error = CollabError(
        message: m["message"]?.stringValue ?? "Error", code: m["code"]?.stringValue ?? "error"
      )
      if let room {
        if !room.state.synced {
          state.withValue { s in if s.rooms[room.id] === room { s.rooms[room.id] = nil } }
          room.fail(error)
          return
        }
        if let id = m["id"]?.intValue {
          let retry = room.state.withValue { s -> Bool in
            guard let update = s.inflight.removeValue(forKey: id) else { return false }
            guard error.code == "rate_limited" else { return false }
            s.pending.insert(update, at: 0)
            return true
          }
          if retry {
            Task { [weak self] in
              try? await Task.sleep(nanoseconds: 1_000_000_000)
              self?.flush(room)
            }
          }
        }
        room.emitError(error)
        return
      }
      if error.code == "unauthorized" || error.message.range(of: "token|API key", options: [.regularExpression, .caseInsensitive]) != nil {
        for r in state.withValue({ Array($0.rooms.values) }) { r.fail(error) }
      }
    default:
      break
    }
  }

  private func joined(_ room: CollabRoom, _ m: JSONObject) {
    let write = m["write"]?.boolValue ?? false
    let seq = m["seq"]?.intValue ?? 0
    room.state.withValue {
      $0.write = write
      $0.seq = seq
      $0.joined = true
    }
    for update in m["updates"]?.arrayValue ?? [] { if let s = update.stringValue { room.apply(s) } }
    var peers: [String: JSONObject] = [:]
    for p in m["peers"]?.arrayValue ?? [] {
      if let o = p.objectValue, let c = o["client"]?.stringValue { peers[c] = o["state"]?.objectValue ?? [:] }
    }
    let joinedPeers = peers
    let (dropped, presence, first, ready) = room.state.withValue {
      s -> (Bool, JSONObject?, Bool, CheckedContinuation<Void, any Error>?) in
      s.peers = joinedPeers
      // anything sent before the connection dropped and not confirmed goes again (applying an update twice is harmless)
      let unconfirmed = s.inflight.sorted { $0.key < $1.key }.map(\.value)
      s.pending.insert(contentsOf: unconfirmed, at: 0)
      s.inflight = [:]
      let dropped = !s.write && !s.pending.isEmpty
      if !s.write { s.pending = [] }
      let first = !s.synced
      s.synced = true
      let ready = first ? s.ready : nil
      if first { s.ready = nil }
      return (dropped, s.presence, first, ready)
    }
    if dropped {
      room.emitError(
        CollabError(message: "You can read this document but not edit it; your changes were not saved", code: "forbidden")
      )
    }
    if let presence { send(["t": "presence", "doc": .string(room.id), "state": .object(presence)], room: room) }
    room.emitSynced()
    room.emitPresence()
    if first { ready?.resume() }
    flush(room)
    let count = m["count"]?.intValue ?? 0
    if write && count > compactAfter {
      let data = room.document.encodeStateAsUpdate().base64EncodedString()
      send(["t": "compact", "doc": .string(room.id), "upto": .integer(seq), "data": .string(data)], room: room)
    }
  }

  /// Sends a fresh token before the current one expires (the server closes the connection when it does).
  private func scheduleTokenRefresh() {
    let task = Task { [weak self] in
      guard let self, let token = await self.token(), let exp = JWT.decodePayload(token)?["exp"] as? Double else {
        return
      }
      let wait = max(5, exp - Date().timeIntervalSince1970 - 60)
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled else { return }
      let fresh = await self.token()
      self.send(["t": "auth", "apikey": .string(self.apikey), "token": fresh.map(AnyJSON.string) ?? .null], room: nil)
    }
    state.withValue {
      $0.refresh?.cancel()
      $0.refresh = task
    }
  }

  // MARK: Rooms

  static func encode(_ message: JSONObject) -> String {
    (try? String(decoding: JSONEncoder().encode(message), as: UTF8.self)) ?? "{}"
  }

  /// Sends when connected (and, for a room's message, when the room has joined).
  func send(_ message: JSONObject, room: CollabRoom?) {
    let socket = state.withValue { $0.ready ? $0.socket : nil }
    guard let socket else { return }
    if let room, !room.state.joined { return }
    socket.send(Self.encode(message))
  }

  func flush(_ room: CollabRoom) {
    let ready = state.ready
    let out = room.state.withValue { s -> Data? in
      if s.joined && !s.write { s.pending = [] }  // read only: edits stay local
      guard ready, s.joined, s.write, !s.pending.isEmpty else { return nil }
      let update = s.pending.count == 1 ? s.pending[0] : yjs.mergeUpdates(s.pending)
      s.pending = []
      return update
    }
    guard let out else { return }
    let id = state.withValue { s -> Int in
      defer { s.nextID += 1 }
      return s.nextID
    }
    room.state.withValue { $0.inflight[id] = out }
    send(
      ["t": "update", "doc": .string(room.id), "data": .string(out.base64EncodedString()), "id": .integer(id)],
      room: room
    )
  }

  func leave(_ room: CollabRoom) {
    let mine = state.withValue { $0.rooms[room.id] === room }
    guard mine else { return }
    send(["t": "leave", "doc": .string(room.id)], room: room)
    state.withValue { $0.rooms[room.id] = nil }
  }
}

final class WeakCollabClient: Sendable {
  private let box: LockIsolated<WeakBox>
  struct WeakBox: @unchecked Sendable { weak var value: CollabClient? }
  init(_ client: CollabClient) { box = LockIsolated(WeakBox(value: client)) }
  var value: CollabClient? { box.value.value }
}

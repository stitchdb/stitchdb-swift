import ConcurrencyExtras
public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Push notifications and the in-app inbox (`stitchdb.push`, Studio › Integrations › Push): the app registers the device
// token it got from the system (APNs on Apple platforms, FCM on Android, a PushSubscription in browsers) for the
// signed-in user, subscribes devices to topics and reads the user's inbox. Sending needs the service key (server side).
// The SDK does not ask for notification permission or fetch tokens itself: that stays with your app
// (`UIApplication.registerForRemoteNotifications()` and `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`).

/// A request to `/push/v1` failed: `status` is the HTTP status (401 without a signed-in user, 0 without an answer).
public struct PushError: Error, LocalizedError, Sendable, Equatable, ServiceError {
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

/// The push service a device token belongs to.
public enum PushPlatform: String, Codable, Sendable {
  /// Apple Push Notification service (iOS, iPadOS, macOS, watchOS, tvOS, visionOS).
  case ios
  /// Android, through FCM.
  case android
  /// Web Push (a browser's PushSubscription).
  case web
}

/// A device to register: the token your app got from the push service.
public struct PushDevice: Encodable, Sendable, Equatable {
  public var platform: PushPlatform
  /// The APNs device token (hex) or the FCM registration token; nil for web.
  public var token: String?
  /// Web Push only: the subscription's endpoint and keys.
  public var endpoint: String?
  public var p256dh: String?
  public var auth: String?
  /// Topics to put the device in (replaces its topics; nil keeps them).
  public var topics: [String]?
  /// Which of your apps this is (a bundle id, when several apps share the project).
  public var app: String?

  public init(
    platform: PushPlatform, token: String? = nil, endpoint: String? = nil, p256dh: String? = nil, auth: String? = nil,
    topics: [String]? = nil, app: String? = nil
  ) {
    self.platform = platform
    self.token = token
    self.endpoint = endpoint
    self.p256dh = p256dh
    self.auth = auth
    self.topics = topics
    self.app = app
  }

  /// An APNs device token as the system hands it to the app delegate (the bytes, sent as hex).
  public static func apns(_ deviceToken: Data, topics: [String]? = nil, app: String? = nil) -> PushDevice {
    PushDevice(platform: .ios, token: PushClient.hexToken(deviceToken), topics: topics, app: app)
  }

  /// An APNs device token that is already hex.
  public static func apns(token: String, topics: [String]? = nil, app: String? = nil) -> PushDevice {
    PushDevice(platform: .ios, token: token, topics: topics, app: app)
  }

  /// An FCM registration token.
  public static func fcm(token: String, topics: [String]? = nil, app: String? = nil) -> PushDevice {
    PushDevice(platform: .android, token: token, topics: topics, app: app)
  }

  /// A browser PushSubscription (its `endpoint` and `keys.p256dh`, `keys.auth`).
  public static func web(endpoint: String, p256dh: String, auth: String, topics: [String]? = nil) -> PushDevice {
    PushDevice(platform: .web, endpoint: endpoint, p256dh: p256dh, auth: auth, topics: topics)
  }

  enum CodingKeys: String, CodingKey {
    case platform, token, subscription, topics, app
  }

  enum SubscriptionKeys: String, CodingKey {
    case endpoint, keys
  }

  enum KeyKeys: String, CodingKey {
    case p256dh, auth
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(platform, forKey: .platform)
    if platform == .web {
      var s = c.nestedContainer(keyedBy: SubscriptionKeys.self, forKey: .subscription)
      try s.encode(endpoint ?? "", forKey: .endpoint)
      var k = s.nestedContainer(keyedBy: KeyKeys.self, forKey: .keys)
      try k.encode(p256dh ?? "", forKey: .p256dh)
      try k.encode(auth ?? "", forKey: .auth)
    } else {
      try c.encode(token ?? "", forKey: .token)
    }
    try c.encodeIfPresent(topics, forKey: .topics)
    try c.encodeIfPresent(app, forKey: .app)
  }
}

/// Which platforms are set up for the project, and its Web Push public key.
public struct PushConfig: Decodable, Sendable, Equatable {
  public let vapidPublicKey: String?
  public let ios: Bool
  public let android: Bool
  public let web: Bool

  enum CodingKeys: String, CodingKey {
    case ios, android, web
    case vapidPublicKey = "vapid_public_key"
  }
}

/// A registered device.
public struct PushRegistration: Decodable, Sendable, Equatable {
  public let id: String
  public let platform: PushPlatform
  public let topics: [String]
  public let createdAt: String?

  enum CodingKeys: String, CodingKey {
    case id, platform, topics
    case createdAt = "created_at"
  }
}

/// A notification to send (service key). Pass one of `userID`, `userIDs` or `topic`.
public struct PushMessage: Encodable, Sendable, Equatable {
  public var userID: String?
  /// Up to 10,000 users.
  public var userIDs: [String]?
  public var topic: String?
  public var title: String?
  public var body: String?
  /// Extra data for your app (up to 3 KB).
  public var data: JSONObject?
  public var badge: Int?
  public var sound: String?
  /// Also store it in the users' in-app inbox (default true; not for topics).
  public var inbox: Bool?
  /// Send later.
  public var sendAt: Date?

  public init(
    userID: String? = nil, userIDs: [String]? = nil, topic: String? = nil, title: String? = nil, body: String? = nil,
    data: JSONObject? = nil, badge: Int? = nil, sound: String? = nil, inbox: Bool? = nil, sendAt: Date? = nil
  ) {
    self.userID = userID
    self.userIDs = userIDs
    self.topic = topic
    self.title = title
    self.body = body
    self.data = data
    self.badge = badge
    self.sound = sound
    self.inbox = inbox
    self.sendAt = sendAt
  }

  enum CodingKeys: String, CodingKey {
    case topic, title, body, data, badge, sound, inbox
    case userID = "user_id"
    case userIDs = "user_ids"
    case sendAt = "send_at"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(userID, forKey: .userID)
    try c.encodeIfPresent(userIDs, forKey: .userIDs)
    try c.encodeIfPresent(topic, forKey: .topic)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(body, forKey: .body)
    try c.encodeIfPresent(data, forKey: .data)
    try c.encodeIfPresent(badge, forKey: .badge)
    try c.encodeIfPresent(sound, forKey: .sound)
    try c.encodeIfPresent(inbox, forKey: .inbox)
    try c.encodeIfPresent(sendAt.map(serviceIsoString), forKey: .sendAt)
  }
}

/// The answer of ``PushClient/send(_:)``: the message id to look up with ``PushClient/status(_:)``.
public struct PushSendResult: Decodable, Sendable, Equatable {
  public let id: Int
  /// `queued`.
  public let status: String
}

/// The delivery result of a sent message.
public struct PushMessageStatus: Decodable, Sendable, Equatable {
  public let id: Int
  /// `queued`, `sending`, `sent`, `partial`, `failed` or `no_devices`.
  public let status: String
  public let devices: Int?
  public let sent: Int?
  public let failed: Int?
  public let error: String?
  public let createdAt: String?
  public let finishedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, status, devices, sent, failed, error
    case createdAt = "created_at"
    case finishedAt = "finished_at"
  }
}

/// One notification in the signed-in user's in-app inbox.
public struct InboxNotification: Codable, Sendable, Equatable {
  public let id: Int
  public let title: String?
  public let body: String?
  public let data: JSONObject
  public let createdAt: String
  public let readAt: String?

  public init(id: Int, title: String?, body: String?, data: JSONObject = [:], createdAt: String, readAt: String? = nil) {
    self.id = id
    self.title = title
    self.body = body
    self.data = data
    self.createdAt = createdAt
    self.readAt = readAt
  }

  enum CodingKeys: String, CodingKey {
    case id, title, body, data
    case createdAt = "created_at"
    case readAt = "read_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // the inbox answers with numbers; a Realtime insert carries the bigint id as a number or a string
    if let n = try? c.decode(Int.self, forKey: .id) {
      id = n
    } else {
      id = Int(try c.decode(String.self, forKey: .id)) ?? 0
    }
    title = try c.decodeIfPresent(String.self, forKey: .title)
    body = try c.decodeIfPresent(String.self, forKey: .body)
    data = try c.decodeIfPresent(JSONObject.self, forKey: .data) ?? [:]
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    readAt = try c.decodeIfPresent(String.self, forKey: .readAt)
  }
}

/// A page of the inbox and the number of unread notifications.
public struct PushInbox: Decodable, Sendable, Equatable {
  public let notifications: [InboxNotification]
  public let unread: Int
}

private struct RemovedAnswer: Decodable { let removed: Int }
private struct DevicesAnswer: Decodable { let devices: Int }
private struct MarkedAnswer: Decodable { let marked: Int }
private struct DeletedCount: Decodable { let deleted: Int }

/// Push notifications and the in-app inbox. Use the one on ``StitchClient/push``.
///
/// ```swift
/// // AppDelegate: the system handed you the APNs token
/// func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
///   Task { try await stitchdb.push.register(.apns(token, topics: ["news"])) }
/// }
///
/// let inbox = try await stitchdb.push.inbox(unread: true)
/// let stop = try await stitchdb.push.onNotification { note in showBanner(note.title) }
/// ```
public final class PushClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  /// Opens a Realtime channel for the inbox listener; removes one.
  typealias Channels = (
    open: @Sendable (_ name: String) -> RealtimeChannelV2?, remove: @Sendable (_ channel: RealtimeChannelV2) async -> Void
  )

  let http: ServiceHTTP
  private let channels: LockIsolated<Channels?>
  private let currentUserID: @Sendable () async -> String?

  init(
    url: URL, headers: [String: String], channels: Channels? = nil,
    currentUserID: @escaping @Sendable () async -> String? = { nil }, fetch: Fetch? = nil
  ) {
    http = ServiceHTTP(url: url, headers: headers, fetch: fetch)
    self.channels = LockIsolated(channels)
    self.currentUserID = currentUserID
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  func setChannels(
    open: @escaping @Sendable (_ name: String) -> RealtimeChannelV2?,
    remove: @escaping @Sendable (_ channel: RealtimeChannelV2) async -> Void
  ) {
    channels.setValue((open: open, remove: remove))
  }

  /// The APNs device token bytes as the lowercase hex the push service expects.
  public static func hexToken(_ deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
  }

  /// Which platforms are set up for this project, and the Web Push public key (VAPID).
  public func config() async throws -> PushConfig {
    try await http.send("GET", ["config"], as: PushConfig.self, error: PushError.self)
  }

  /// Registers this device for the signed-in user. Call it after sign-in and whenever the system hands you a new
  /// token; the same token moves to the user who registered it last.
  @discardableResult
  public func register(_ device: PushDevice) async throws -> PushRegistration {
    try await http.send("POST", ["devices"], body: device, as: PushRegistration.self, error: PushError.self)
  }

  /// Removes this device from the signed-in user (call it before signing out). Returns how many were removed.
  @discardableResult
  public func unregister(_ device: PushDevice) async throws -> Int {
    try await http.send("DELETE", ["devices"], body: device, as: RemovedAnswer.self, error: PushError.self).removed
  }

  /// Subscribes the signed-in user's devices (or only `device`) to a topic. Returns how many devices changed.
  @discardableResult
  public func subscribe(topic: String, device: PushDevice? = nil) async throws -> Int {
    try await topicRequest(topic, "subscribe", device)
  }

  /// Takes the signed-in user's devices (or only `device`) out of a topic.
  @discardableResult
  public func unsubscribe(topic: String, device: PushDevice? = nil) async throws -> Int {
    try await topicRequest(topic, "unsubscribe", device)
  }

  private func topicRequest(_ topic: String, _ action: String, _ device: PushDevice?) async throws -> Int {
    let path = ["topics", topic, action]
    if let device {
      return try await http.send("POST", path, body: device, as: DevicesAnswer.self, error: PushError.self).devices
    }
    return try await http.send("POST", path, body: JSONObject(), as: DevicesAnswer.self, error: PushError.self).devices
  }

  /// Sends a notification (service key only: your server or an Edge Function). Delivered within a second or two.
  public func send(_ message: PushMessage) async throws -> PushSendResult {
    try await http.send("POST", ["send"], body: message, as: PushSendResult.self, error: PushError.self)
  }

  /// The delivery result of a sent message (service key).
  public func status(_ id: Int) async throws -> PushMessageStatus {
    try await http.send("GET", ["messages", String(id)], as: PushMessageStatus.self, error: PushError.self)
  }

  /// The signed-in user's in-app inbox, newest first. `before` is a notification id, for the next page.
  public func inbox(unread: Bool = false, limit: Int? = nil, before: Int? = nil) async throws -> PushInbox {
    let query = queryItems([
      ("unread", unread ? "true" : nil), ("limit", limit.map(String.init)), ("before", before.map(String.init)),
    ])
    return try await http.send("GET", ["inbox"], query: query, as: PushInbox.self, error: PushError.self)
  }

  /// Marks notifications read; returns how many changed.
  @discardableResult
  public func markRead(_ ids: [Int]) async throws -> Int {
    try await http.send("POST", ["inbox", "read"], body: ["ids": ids], as: MarkedAnswer.self, error: PushError.self)
      .marked
  }

  /// Marks every notification of the signed-in user read.
  @discardableResult
  public func markAllRead() async throws -> Int {
    try await http.send("POST", ["inbox", "read"], body: ["all": true], as: MarkedAnswer.self, error: PushError.self)
      .marked
  }

  /// Deletes notifications from the inbox; returns how many were deleted.
  @discardableResult
  public func deleteNotifications(_ ids: [Int]) async throws -> Int {
    try await http.send("POST", ["inbox", "delete"], body: ["ids": ids], as: DeletedCount.self, error: PushError.self)
      .deleted
  }

  /// New inbox notifications for the signed-in user, live (Realtime). Returns a function that stops listening.
  public func onNotification(
    _ callback: @escaping @Sendable (InboxNotification) -> Void
  ) async throws -> @Sendable () async -> Void {
    guard let uid = await currentUserID() else { throw PushError(message: "Sign in first", status: 401) }
    guard let channels = channels.value, let channel = channels.open("push-inbox-\(uid)") else {
      throw PushError(message: "Realtime is not available", status: 0)
    }
    let subscription = channel.onPostgresChange(
      InsertAction.self, schema: "push", table: "notifications", filter: .eq("user_id", value: uid)
    ) { action in
      if let note = try? AnyJSON.object(action.record).decode(as: InboxNotification.self) { callback(note) }
    }
    try await channel.subscribeWithError()
    let remove = channels.remove
    return {
      subscription.cancel()
      await remove(channel)
    }
  }
}

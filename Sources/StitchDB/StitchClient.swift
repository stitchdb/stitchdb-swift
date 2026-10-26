import ConcurrencyExtras
public import Foundation
import HTTPTypes
import IssueReporting

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

/// The unified client for all StitchDB services.
///
/// Create one instance per StitchDB project and share it across your app.
///
/// ```swift
/// let stitchdb = StitchClient(
///   stitchURL: URL(string: "https://<project-ref>.p.stitchdb.com")!,
///   stitchKey: "your-anon-key"
/// )
/// ```
///
/// ## Topics
///
/// ### Creating a Client
/// - ``init(stitchURL:stitchKey:)``
/// - ``init(stitchURL:stitchKey:options:)``
///
/// ### StitchDB Services
/// - ``auth``
/// - ``storage``
/// - ``functions``
/// - ``realtimeV2``
///
/// ### Querying the Database
/// - ``from(_:)``
/// - ``rpc(_:params:count:)``
/// - ``rpc(_:count:)``
/// - ``schema(_:)``
///
/// ### Realtime Channels
/// - ``channels``
/// - ``channel(_:options:)``
/// - ``removeChannel(_:)``
/// - ``removeAllChannels()``
///
/// ### Deep Links
/// - ``handle(_:)``
///
/// ### Configuration
/// - ``headers``
///
/// ## OpenTelemetry Trace Propagation
///
/// Enable the `OpenTelemetry` trait on your dependency declaration to have every outgoing
/// request automatically carry a W3C `traceparent` header derived from the currently active
/// OpenTelemetry span:
///
/// ```swift
/// .package(
///   url: "https://github.com/stitchdb/stitchdb-swift",
///   from: "2.0.0",
///   traits: ["OpenTelemetry"]
/// )
/// ```
///
/// No further configuration is needed — the trait is the only toggle. With it enabled, whatever
/// span is active (via `opentelemetry-swift`) when a request is made gets propagated; with no
/// active span, or with the trait disabled, requests go out unchanged.
public final class StitchClient: Sendable {
  let options: StitchClientOptions
  let stitchURL: URL
  let stitchKey: String
  let storageURL: URL
  let databaseURL: URL
  let functionsURL: URL
  let clock: any Clock<Duration>

  private let _auth: AuthClient

  /// The Auth client for managing user sessions and authentication.
  ///
  /// Use this property to sign users in and out, retrieve the current session,
  /// and listen for authentication state changes.
  ///
  /// > Warning: Do not access this property when ``StitchClientOptions/AuthOptions/accessToken``
  /// > is configured — the client will emit a runtime issue. Use a separate ``StitchClient``
  /// > without `accessToken` if you need both StitchDB Auth and a third-party auth provider.
  public var auth: AuthClient {
    if options.auth.accessToken != nil {
      reportIssue(
        """
        StitchDB Client is configured with the auth.accessToken option,
        accessing stitch.auth is not possible.
        """
      )
    }
    return _auth
  }

  var rest: PostgrestClient {
    mutableState.withValue {
      if $0.rest == nil {
        $0.rest = PostgrestClient(
          url: databaseURL,
          schema: options.db.schema,
          headers: headers,
          logger: options.global.logger,
          fetch: fetchWithAuth,
          encoder: options.db.encoder,
          decoder: options.db.decoder
        )
      }

      return $0.rest!
    }
  }

  /// The Storage client for uploading, downloading, and managing files.
  public var storage: StitchStorageClient {
    mutableState.withValue {
      if $0.storage == nil {
        $0.storage = StitchStorageClient(
          configuration: StorageClientConfiguration(
            url: storageURL,
            headers: headers,
            session: StorageHTTPSession(fetch: fetchWithAuth, upload: uploadWithAuth),
            logger: options.global.logger,
            useNewHostname: options.storage.useNewHostname
          )
        )
      }

      return $0.storage!
    }
  }

  let _realtime: UncheckedSendable<RealtimeClient>

  /// The Realtime client for subscribing to database changes and broadcasting presence events.
  public var realtimeV2: RealtimeClientV2 {
    mutableState.withValue {
      if $0.realtime == nil {
        $0.realtime = _initRealtimeClient()
      }
      return $0.realtime!
    }
  }

  /// The Functions client for invoking StitchDB Edge Functions.
  public var functions: FunctionsClient {
    mutableState.withValue {
      if $0.functions == nil {
        var functionsHeaders = _headers
        if APIKeyFormat.isNew(stitchKey) {
          functionsHeaders[.authorization] = nil
        }
        $0.functions = FunctionsClient(
          url: functionsURL,
          headers: functionsHeaders.dictionary,
          region: options.functions.region,
          logger: options.global.logger,
          fetch: fetchWithAuth,
          decoder: options.functions.decoder
        )
      }

      return $0.functions!
    }
  }

  /// Crash and error reporting: uncaught exceptions and the errors you report, with breadcrumbs of the last API
  /// calls. Nothing is captured or sent before ``CrashesClient/start(release:environment:captureUnhandled:maxBreadcrumbs:directory:beforeSend:)``.
  public let crashes: CrashesClient

  /// Product analytics: the events your app tracks, linked to the signed-in user, for active users, funnels and
  /// retention in Studio › Analytics. Nothing is sent before ``AnalyticsClient/start(release:beforeSend:flushInterval:)``.
  public let analytics: AnalyticsClient

  /// Deep links and short links (Studio › Links): resolve the link the app was opened with, the link that led to an
  /// install (``LinksClient/deferred(platform:referrer:force:)``), and make links.
  public let links: LinksClient

  let _headers: HTTPFields
  /// The HTTP headers included in every request made by sub-clients.
  ///
  /// This dictionary is read-only. To supply custom headers, set
  /// ``StitchClientOptions/GlobalOptions/headers`` when initializing the client.
  public var headers: [String: String] {
    _headers.dictionary
  }

  struct MutableState {
    var listenForAuthEventsTask: Task<Void, Never>?
    var storage: StitchStorageClient?
    var rest: PostgrestClient?
    var functions: FunctionsClient?
    var realtime: RealtimeClientV2?

    var changedAccessToken: String?
  }

  let mutableState = LockIsolated(MutableState())

  #if !os(Linux) && !os(Android)
    /// Creates a client with default options.
    /// - Parameters:
    ///   - stitchURL: Your StitchDB project URL, found in the project dashboard.
    ///   - stitchKey: Your StitchDB project anon key, found in the project dashboard.
    public convenience init(stitchURL: URL, stitchKey: String) {
      self.init(
        stitchURL: stitchURL,
        stitchKey: stitchKey,
        options: StitchClientOptions()
      )
    }
  #endif

  /// Creates a client with custom options.
  /// - Parameters:
  ///   - stitchURL: Your StitchDB project URL, found in the project dashboard.
  ///   - stitchKey: Your StitchDB project anon key, found in the project dashboard.
  ///   - options: Configuration options for the client and its sub-clients.
  public convenience init(
    stitchURL: URL,
    stitchKey: String,
    options: StitchClientOptions
  ) {
    self.init(
      stitchURL: stitchURL,
      stitchKey: stitchKey,
      options: options,
      clock: ContinuousClock()
    )
  }

  /// `package`-visibility so callers in other targets of this package (e.g. `IntegrationTests`)
  /// can inject a test clock without exposing it publicly.
  package init(
    stitchURL: URL,
    stitchKey: String,
    options: StitchClientOptions,
    clock: any Clock<Duration>
  ) {
    self.stitchURL = stitchURL
    self.stitchKey = stitchKey
    self.options = options
    self.clock = clock

    APIKeyFormat.checkFormat(stitchKey)

    storageURL = stitchURL.appendingPathComponent("/storage/v1")
    databaseURL = stitchURL.appendingPathComponent("/rest/v1")
    functionsURL = stitchURL.appendingPathComponent("/functions/v1")

    _headers = HTTPFields(defaultHeaders)
      .merging(
        with: HTTPFields(
          [
            "Authorization": "Bearer \(stitchKey)",
            "Apikey": stitchKey,
          ]
        )
      )
      .merging(with: HTTPFields(options.global.headers))

    // default storage key uses the stitchdb project ref as a namespace
    guard let host = stitchURL.host(percentEncoded: false) else {
      preconditionFailure("stitchURL must have a valid host.")
    }
    let defaultStorageKey = "stitchdb-\(host.split(separator: ".")[0])-auth-token"

    let crashes = CrashesClient(
      url: stitchURL.appendingPathComponent("/crashes/v1"),
      headers: _headers.dictionary,
      directory: Self.crashesDirectory(for: stitchURL)
    )
    self.crashes = crashes

    let auth = AuthClient(
      url: stitchURL.appendingPathComponent("/auth/v1"),
      headers: _headers.dictionary,
      flowType: options.auth.flowType,
      redirectToURL: options.auth.redirectToURL,
      storageKey: options.auth.storageKey ?? defaultStorageKey,
      localStorage: options.auth.storage,
      logger: options.global.logger,
      encoder: options.auth.encoder,
      decoder: options.auth.decoder,
      fetch: { request in
        // DON'T use `fetchWithAuth` method within the AuthClient as it may cause a deadlock.
        try await crashes.recording(request) {
          try await options.global.session.data(for: TraceContext.inject(into: request))
        }
      },
      autoRefreshToken: options.auth.autoRefreshToken,
      emitLocalSessionAsInitialSession: options.auth.emitLocalSessionAsInitialSession
    )
    _auth = auth

    analytics = AnalyticsClient(
      url: stitchURL.appendingPathComponent("/analytics/v1"),
      headers: _headers.dictionary,
      directory: Self.analyticsDirectory(for: stitchURL),
      logger: options.global.logger,
      authChanges: { handler in
        // sign-in and sign-out only: a token refresh keeps the same user
        let task = Task { [changes = auth.authStateChanges] in
          for await (event, _) in changes where [.signedIn, .signedOut, .userDeleted].contains(event) {
            handler()
          }
        }
        return { task.cancel() }
      }
    )

    links = LinksClient(
      url: stitchURL.appendingPathComponent("/links/v1"),
      headers: _headers.dictionary,
      directory: Self.linksDirectory(for: stitchURL)
    )

    _realtime = UncheckedSendable(
      RealtimeClient(
        stitchURL.appendingPathComponent("/realtime/v1").absoluteString,
        headers: _headers.dictionary,
        params: _headers.dictionary
      )
    )

    crashes.setFetch { [session = options.global.session, adapt = adaptRequest] request in
      try await session.data(for: adapt(request))
    }
    analytics.setFetch { [session = options.global.session, adapt = adaptRequest] request in
      try await session.data(for: adapt(request))
    }
    links.setFetch(fetchWithAuth)

    if options.auth.accessToken == nil {
      listenForAuthEvents()
    }
  }

  /// Creates a query builder targeting a table or view.
  /// - Parameter table: The name of the table or view to query.
  /// - Returns: A query builder for constructing and executing the query.
  public func from(_ table: String) -> PostgrestQueryBuilder {
    rest.from(table)
  }

  /// Calls a Postgres function.
  /// - Parameters:
  ///   - fn: The name of the function to call.
  ///   - params: The parameters to pass to the function.
  ///   - count: The count algorithm to apply to rows returned by set-returning functions.
  /// - Returns: A filter builder for further narrowing the result set.
  /// - Throws: If encoding `params` fails or the function call returns an error.
  public func rpc(
    _ fn: String,
    params: some Encodable,
    count: CountOption? = nil
  ) throws -> PostgrestFilterBuilder {
    try rest.rpc(fn, params: params, count: count)
  }

  /// Calls a Postgres function with no parameters.
  /// - Parameters:
  ///   - fn: The name of the function to call.
  ///   - count: The count algorithm to apply to rows returned by set-returning functions.
  /// - Returns: A filter builder for further narrowing the result set.
  /// - Throws: If the function call returns an error.
  public func rpc(
    _ fn: String,
    count: CountOption? = nil
  ) throws -> PostgrestFilterBuilder {
    try rest.rpc(fn, count: count)
  }

  /// Returns a database client scoped to the given Postgres schema.
  ///
  /// The schema must be on the list of exposed schemas in your StitchDB project dashboard.
  /// - Parameter schema: The schema to query.
  /// - Returns: A ``PostgrestClient`` configured for the given schema.
  public func schema(_ schema: String) -> PostgrestClient {
    rest.schema(schema)
  }

  /// All active Realtime channels.
  public var channels: [RealtimeChannelV2] {
    Array(realtimeV2.subscriptions.values)
  }

  /// Creates a Realtime channel with support for Broadcast, Presence, and Postgres Changes.
  /// - Parameters:
  ///   - name: A unique name for the channel.
  ///   - options: A closure to configure broadcast, presence, and Postgres change options.
  /// - Returns: A configured ``RealtimeChannelV2`` ready to subscribe.
  public func channel(
    _ name: String,
    options: @Sendable (inout RealtimeChannelConfig) -> Void = { _ in }
  ) -> RealtimeChannelV2 {
    realtimeV2.channel(name, options: options)
  }

  /// Unsubscribes from and removes a Realtime channel.
  /// - Parameter channel: The channel to remove.
  public func removeChannel(_ channel: RealtimeChannelV2) async {
    await realtimeV2.removeChannel(channel)
  }

  /// Unsubscribes from and removes all active Realtime channels.
  public func removeAllChannels() async {
    await realtimeV2.removeAllChannels()
  }

  /// Passes an incoming URL to the Auth client for processing deep links and OAuth callbacks.
  ///
  /// Call this from your app's URL-handling entry points so Auth can complete OAuth and
  /// magic-link flows.
  ///
  /// ## Usage example:
  ///
  /// ### UIKit app lifecycle
  ///
  /// In your `AppDelegate.swift`:
  ///
  /// ```swift
  /// public func application(
  ///   _ application: UIApplication,
  ///   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  /// ) -> Bool {
  ///   if let url = launchOptions?[.url] as? URL {
  ///     stitchdb.handle(url)
  ///   }
  ///
  ///   return true
  /// }
  ///
  /// func application(
  ///   _ app: UIApplication,
  ///   open url: URL,
  ///   options: [UIApplication.OpenURLOptionsKey: Any]
  /// ) -> Bool {
  ///   stitchdb.handle(url)
  ///   return true
  /// }
  /// ```
  ///
  /// ### UIKit app lifecycle with scenes
  ///
  /// In your `SceneDelegate.swift`:
  ///
  /// ```swift
  /// func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
  ///   guard let url = URLContexts.first?.url else { return }
  ///   stitchdb.handle(url)
  /// }
  /// ```
  ///
  /// ### SwiftUI app lifecycle
  ///
  /// In your `AppDelegate.swift`:
  ///
  /// ```swift
  /// SomeView()
  ///   .onOpenURL { url in
  ///     stitchdb.handle(url)
  ///   }
  /// ```
  public func handle(_ url: URL) {
    auth.handle(url)
  }

  deinit {
    mutableState.listenForAuthEventsTask?.cancel()
  }

  /// A `fetch` closure handed to the REST, Storage and Functions sub-clients.
  ///
  /// Captures only the dependencies it needs — never `self` — because each sub-client stores this
  /// closure for its whole lifetime while being cached in ``mutableState``. Capturing `self` here
  /// would form a `self -> mutableState -> sub-client -> closure -> self` retain cycle that keeps
  /// ``deinit`` from ever running.
  var fetchWithAuth: @Sendable (_ request: URLRequest) async throws -> (Data, URLResponse) {
    { [session = options.global.session, adapt = adaptRequest, crashes] request in
      try await crashes.recording(request) { try await session.data(for: adapt(request)) }
    }
  }

  /// An `upload` closure handed to the Storage sub-client.
  ///
  /// Same no-`self`-capture rationale as ``fetchWithAuth``.
  private var uploadWithAuth:
    @Sendable (_ request: URLRequest, _ data: Data) async throws -> (Data, URLResponse)
  {
    { [session = options.global.session, adapt = adaptRequest, crashes] request, data in
      try await crashes.recording(request) { try await session.upload(for: adapt(request), from: data) }
    }
  }

  /// Builds a request adapter that injects trace context and the current access token.
  ///
  /// The returned closure captures the auth dependencies by value instead of `self`. `AuthClient`
  /// holds no reference back to ``StitchClient``, so no cycle is formed.
  private var adaptRequest: @Sendable (_ request: URLRequest) async -> URLRequest {
    { [getAccessToken = accessTokenProvider] request in
      let token = try? await getAccessToken()

      var request = TraceContext.inject(into: request)
      if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      return request
    }
  }

  /// Resolves the access token to send on outgoing requests, without capturing `self`.
  private var accessTokenProvider: @Sendable () async throws -> String? {
    { [accessToken = options.auth.accessToken, auth = _auth] in
      if let accessToken {
        try await accessToken()
      } else {
        try await auth.session.accessToken
      }
    }
  }

  private func _getAccessToken() async throws -> String? {
    try await accessTokenProvider()
  }

  /// Mirrors Auth state onto the Functions and Realtime sub-clients for the client's lifetime.
  ///
  /// `authStateChanges` never finishes on its own, so the observing task must not capture `self`
  /// strongly: it would keep the client alive forever, and ``deinit`` — the only place that
  /// cancels this task — could never run. The stream is therefore resolved up front (so the task
  /// doesn't need `self` to reach `auth`) and `self` is captured weakly.
  private func listenForAuthEvents() {
    let task = Task { [weak self, authStateChanges = _auth.authStateChanges] in
      for await (event, session) in authStateChanges {
        // `handleTokenChanged` needs a live client; once it's gone there is nothing to update.
        guard let self else { return }
        await self.handleTokenChanged(event: event, session: session)
      }
    }
    mutableState.withValue {
      $0.listenForAuthEventsTask = task
    }
  }

  private func handleTokenChanged(event: AuthChangeEvent, session: Session?) async {
    let accessToken: String? = mutableState.withValue {
      if [.initialSession, .signedIn, .tokenRefreshed].contains(event),
        $0.changedAccessToken != session?.accessToken
      {
        $0.changedAccessToken = session?.accessToken
        return session?.accessToken ?? stitchKey
      }

      if event == .signedOut {
        $0.changedAccessToken = nil
        return stitchKey
      }

      return nil
    }

    if let accessToken {
      functions.setAuth(
        token: APIKeyFormat.functionsBearerToken(accessToken: accessToken, stitchKey: stitchKey)
      )
      realtime.setAuth(accessToken)
      await realtimeV2.setAuth(accessToken)
    }
  }

  private func _initRealtimeClient() -> RealtimeClientV2 {
    var realtimeOptions = options.realtime
    realtimeOptions.headers.merge(with: _headers)

    if realtimeOptions.logger == nil {
      realtimeOptions.logger = options.global.logger
    }

    if realtimeOptions.fetch == nil {
      realtimeOptions.fetch = { [session = options.global.session, crashes] request in
        try await crashes.recording(request) { try await session.data(for: TraceContext.inject(into: request)) }
      }
    }

    if realtimeOptions.session == nil {
      realtimeOptions.session = options.global.session
    }

    if realtimeOptions.accessToken == nil {
      realtimeOptions.accessToken = { [weak self] in
        try await self?._getAccessToken()
      }
    } else {
      reportIssue(
        """
        You assigned a custom `accessToken` closure to the RealtimeClientV2. This might not work as you expect
        as StitchClient uses Auth for pulling an access token to send on the realtime channels.

        Please make sure you know what you're doing.
        """
      )
    }

    return RealtimeClientV2(
      url: stitchURL.appendingPathComponent("/realtime/v1"),
      options: realtimeOptions,
      clock: clock
    )
  }
}

# StitchDB Swift

The official Swift client for [StitchDB](https://stitchdb.com): Postgres database, auth, storage, realtime and Edge Functions,
for iOS, macOS, tvOS, watchOS, visionOS and Linux.

## Install

Swift Package Manager:

```swift
dependencies: [
  .package(url: "https://github.com/stitchdb/stitchdb-swift.git", branch: "main")
],
targets: [
  .target(name: "YourApp", dependencies: [.product(name: "StitchDB", package: "stitchdb-swift")])
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste `https://github.com/stitchdb/stitchdb-swift.git`.

Current version: 1.4.1.

## Usage

```swift
import StitchDB

let client = StitchClient(
  stitchURL: URL(string: "https://<project-ref>.p.stitchdb.com")!,
  stitchKey: "<anon-key>"
)

// Database
struct Todo: Codable { let id: Int; let task: String; let isComplete: Bool }
let todos: [Todo] = try await client.from("todos").select().limit(10).execute().value

// Auth
try await client.auth.signIn(email: "ada@example.com", password: "a-strong-password")

// Realtime
let channel = client.channel("room-1")
let changes = channel.postgresChange(InsertAction.self, schema: "public", table: "todos")
try await channel.subscribeWithError()
Task { for await insert in changes { print(insert.record) } }

// Storage
try await client.storage.from("avatars").upload("user-1/avatar.png", data: imageData)

// Edge Functions
struct Hello: Decodable { let message: String }
let hello: Hello = try await client.functions.invoke("hello-world", options: .init(body: ["name": "Ada"]))
```

Find the project URL and anon key in the dashboard under **Settings → API keys**.

## Offline sync

Keep a local copy of the tables that sync (Studio › Database › Offline sync). Reads come from the local copy, writes
apply locally at once and are queued; the queue is pushed and changes are pulled whenever the server can be reached
(every 30 s by default, and after each write).

```swift
let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("offline-\(userID)")
let offline = client.offline(tables: ["todos"], store: FileOfflineStore(directory: dir))
try await offline.ready()

try await offline.table("todos").upsert(["id": .string(UUID().uuidString), "title": "Milk"])
let open = await offline.table("todos").where { $0["done"] != true }

Task { for await rows in offline.table("todos").rowUpdates() { render(rows) } }
Task { for await c in offline.conflicts() { print("\(c.table): server kept", c.server ?? [:]) } }

try await offline.sync()             // push now, pull until up to date
print(await offline.status.pending)  // writes not pushed yet
try await offline.close(clear: true) // on sign-out: stop and delete the local copy
```

A local write wins over pulled changes until it is pushed. If the server keeps its own row (`conflict`) or refuses the
write (`rejected`), the local copy takes the server's row and `conflicts()` gets an event. `MemoryOfflineStore` (the
default) keeps nothing across launches; implement `OfflineStore` for your own storage.

## Crash reporting

Uncaught exceptions and the errors you report, grouped into issues in Studio › Crashes with the stack, app version,
device, the signed-in user and the last breadcrumbs, including the SDK's own API calls
(`GET /rest/v1/orders?select&id 500`: method, path, query keys without values, status, error code).

```swift
client.crashes.start(release: "1.4.0")   // nothing is captured, recorded or sent before start()

do { try await checkout() } catch {
  client.crashes.captureError(error, context: ["step": "payment"])
}
client.crashes.captureMessage("cart is empty after payment")
client.crashes.addBreadcrumb(type: "ui", message: "tapped Checkout")

// consent or filtering: return nil to drop a report
client.crashes.start(release: "1.4.0") { report in userAgreed ? report : nil }

await client.crashes.flush()   // send now (otherwise sent in the background)
client.crashes.stop()          // stop and remove the exception handler
```

Reports wait on disk (at most 30; Application Support on Apple platforms, the temporary directory on Linux, or
`start(directory:)`) until the server has them, and are retried on the next start when the device is offline. Once a
day per install and release a session is sent, for crash-free users. If crash reporting is off for the project, the SDK
stops sending for the run. On Apple platforms uncaught Objective-C exceptions (`NSException`) are written to disk as the
app dies and sent on the next start; the previous handler is still called. Signals (`SIGABRT`, `SIGSEGV`, e.g. from
`fatalError` or a force unwrap of nil) are not captured in this version.

## Analytics

The events your app tracks, linked to the signed-in user (an anonymous id before sign-in, merged into the user when
they sign in), for active users, funnels, retention and breakdowns by release, platform, OS and country in
Studio › Analytics.

```swift
client.analytics.start(release: "1.4.0")   // nothing is sent before start()

client.analytics.track("purchase", props: ["plan": "pro", "amount": 29])

// filtering: change an event or return nil to drop it
client.analytics.start(release: "1.4.0", beforeSend: { event in event.name == "debug" ? nil : event })

await client.analytics.flush()      // send now (otherwise every 10 s or when 20 events wait)
await client.analytics.optOut()     // deletes the user's events and tracks nothing more (remembered on the device)
await client.analytics.optIn()
client.analytics.isOptedOut
client.analytics.anonymousId        // the id of this install before sign-in
client.analytics.stop()             // stop sending; waiting events stay on the device
```

Event names are letters, digits, `_ $ . : - /` and spaces, up to 64 characters (other names are dropped, with a debug
log); props are a JSON object of at most 8 KB. Events tracked before `start()` wait in memory (at most 100). After
start they wait on disk (at most 1000, the oldest are dropped; Application Support on Apple platforms, the temporary
directory on Linux), so events tracked offline survive an app kill and are sent on the next start. Waiting events are
also sent when the user signs in or out (a batch belongs to one user) and, on iOS, when the app goes to the background.
If analytics is off for the project, the SDK stops sending for the run. Calls to the analytics API are not recorded as
crash-report breadcrumbs.

## Deep links

Short links (`https://<project host or your domain>/l/<code>`, made in Studio › Links or from the app) open your app on
the right screen when it is installed (Universal Links) and otherwise send people to the App Store, Google Play or a web
page.

```swift
// the app was opened with a link (SwiftUI .onOpenURL, or a Universal Link's NSUserActivity)
.onOpenURL { url in Task { if let link = try await client.links.resolve(url) { router.open(link.path, link.data) } } }
.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
  Task { if let link = try await client.links.resolve(userActivity: activity) { router.open(link.path, link.data) } }
}

// first launch after an install: the link that led to the install (asked once per install, then nil)
if let first = try await client.links.deferred() { router.open(first.path, first.data) }

// make a link: signed-in users when the project allows it in Studio › Links, any link with the service key
let made = try await client.links.create(LinkInput(path: "/invite/7", data: ["from": "ana"], title: "Join me"))
share(made.url)

// service key: list, stats, change, delete
let page = try await client.links.list(search: "spring", limit: 20)
let stats = try await client.links.get("summer", days: 30)   // clicks per day, platforms, countries, referrers
try await client.links.update("summer", LinkInput(disabled: true))
try await client.links.remove("summer")
```

`resolve` returns nil without a request for a URL that is not a short link (`LinksClient.codeFrom(_:)` gives the code);
an expired or turned-off link throws `LinksError` with status 410. On iOS the platform `ios` is sent by default.
`deferred()` matches the install to a click from the same network and platform within 2 hours (best effort, each click is
handed out once); after an answer it remembers on the device that it asked and returns nil (`force: true` asks again).
For Universal Links add `applinks:<your link host>` to the app's Associated Domains and your Team ID and bundle id in
Studio › Links; StitchDB serves the `apple-app-site-association` file.

## Sign-in extras

```swift
// the project's hosted sign-in page (Studio › Authentication › Hosted sign-in), in a web authentication session
let session = try await client.auth.signInWithHostedPage(redirectTo: URL(string: "myapp://login")!, view: .signUp)
// or only the URL, for your own browser flow; the `sdbl_` code that comes back is exchanged by session(from:)
let url = try client.auth.getHostedPageURL(redirectTo: URL(string: "myapp://login")!, lang: "de")
```

When the project's fake sign-up protection asks for its built-in check (`captcha_required`), `signUp` and
`signInWithOTP` solve it (a small SHA-256 proof of work, on a background task) and send the request once more. They
also add the device's language as `locale` to the user metadata (unless it has `locale`, `language` or `lang`), so auth
e-mails go out in the user's language.

## Push notifications

```swift
// AppDelegate: application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
try await client.push.register(.apns(deviceToken, topics: ["news"]))
try await client.push.subscribe(topic: "offers", device: .apns(deviceToken))

// the in-app inbox
let inbox = try await client.push.inbox(unread: true)
try await client.push.markRead(inbox.notifications.map(\.id))
let stop = try await client.push.onNotification { note in showBanner(note.title) }

// server side, service key
try await admin.push.send(PushMessage(userID: id, title: "Your order shipped", data: ["order": "42"]))
```

## In-app purchases

```swift
// after a StoreKit 2 purchase (or for each update in Transaction.updates)
let result = try await product.purchase()
if case .success(let verification) = result { try await client.purchases.sync(verification) }

if try await client.purchases.hasEntitlement("pro") { unlockPro() }
let state = try await client.purchases.me()   // purchases and active entitlements
```

StitchDB verifies the transaction with the App Store and keeps the user's entitlements; on Linux use
`sync(signedTransaction:)` with the JWS.

## Organizations

```swift
let team = try await client.orgs.create(name: "Acme")
try await client.orgs.invite(team.id, email: "bo@example.com", role: "admin")
let mine = try await client.orgs.list()
try await client.orgs.setActive(team.id)   // the session's org_id / org_role claims are now for Acme
```

Send the header `x-org-id` (`OrgsClient.headerName`) to make `auth.org_id()` another organization the user is a member
of for a request.

## Realtime message history

```swift
let room = client.channel("room:42") { $0.history = RealtimeHistoryConfig(since: Date().addingTimeInterval(-3600)) }
room.onBroadcast(event: "chat") { message in show(message) }   // missed messages first (meta.replayed), then live
try await room.subscribeWithError()
try await room.publish(event: "chat", payload: ["text": "hi"])  // stored, then broadcast
```

## Search, GraphQL and the status page

```swift
let hits = try await client.search("articles", "how do refunds work", options: SearchOptions(limit: 10, mode: .hybrid))

let answer = await client.graphql("query { todosCollection(first: 5) { edges { node { id task } } } }")
if let error = answer.error { print(error.message) }

let page = try await client.status.get()
if page.overall != "operational" { showBanner(page.overallLabel) }
try await client.status.subscribe(email: "ana@example.com")
```

## Feature flags and usage metering

```swift
try await client.flags.load(attributes: ["app_version": "2.4.1"])
if client.flags.isOn("new-checkout") { showNewCheckout() }
let limit = client.flags.get("upload-limit-mb", default: 10)

try await client.metering.record("exports")                 // signed in: meters marked "apps may record"
let usage = try await admin.metering.usage(customer: org.id, group: .month)
```

## Collaborative documents

Yjs documents kept in sync between everyone who has them open, stored with history. The SDK carries Yjs updates as
bytes; plug in any Yjs implementation (for example bindings to the y-crdt Rust library) through `CollabYjs` and
`CollabDocument`.

```swift
let collab = client.collab(yjs: MyYrsAdapter())
let room = try await collab.open("plan-2026", document: myDoc, create: true, title: "Plan 2026")
room.setPresence(["name": "Ann", "cursor": 4])
let token = room.onPresence { peers in drawCursors(peers) }
try await room.snapshot(label: "Before the review")
try await collab.share("plan-2026", userID: bo, role: "editor")
```

## Background jobs and serverless SQL (server side only)

These need secrets that must never ship in an app: use them in a server, a script or a command line tool.

```swift
let admin = StitchClient(stitchURL: projectURL, stitchKey: serviceKey)
let run = try await admin.jobs.start("export", payload: ["user_id": .string(id)], options: JobStartOptions(mode: .long))
let logs = try await admin.jobs.logs(run.id)

// SQL key (Studio › Database › Serverless SQL): runs as the project's owner, past row level security
let sql = try StitchSQL(connection: ProcessInfo.processInfo.environment["STITCHDB_SQL_URL"]!)
let rows = try await sql.query("select * from todos where owner = $1 limit 20", [.string(userID)])
let db = try await sql.connect()   // interactive transactions over a WebSocket session
try await db.transaction { tx in try await tx.query("update accounts set balance = balance - 1 where id = $1", [1]) }
db.close()
```

Documentation: https://stitchdb.com/docs/sdk/swift

## License

MIT. See [LICENSE](LICENSE).

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

Documentation: https://stitchdb.com/docs/sdk/swift

## License

MIT. See [LICENSE](LICENSE).

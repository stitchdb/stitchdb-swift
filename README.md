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

Documentation: https://stitchdb.com/docs/sdk/swift

## License

MIT. See [LICENSE](LICENSE).

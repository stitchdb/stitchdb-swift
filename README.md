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

Documentation: https://stitchdb.com/docs/sdk/swift

## License

MIT. See [LICENSE](LICENSE).

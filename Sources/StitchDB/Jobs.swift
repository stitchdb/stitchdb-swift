public import Foundation
public import Helpers

#if canImport(FoundationNetworking)
  public import FoundationNetworking
#endif

// Durable background jobs (`stitchdb.jobs`, Studio › Edge Functions › Jobs): start runs of a job (an Edge Function
// written with `job()` or `longJob()` from the JavaScript SDK), read them with their steps and logs, cancel and retry
// them. These calls need a client made with the service key: use them on your server, never in an app you ship.

/// A request to `/jobs/v1` failed: `status` is the HTTP status (401 without the service key, 0 without an answer).
public struct JobsError: Error, LocalizedError, Sendable, Equatable, ServiceError {
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

/// The state of a run.
public enum JobStatus: String, Codable, Sendable {
  case queued, running, sleeping, completed, failed, cancelled
}

/// `steps` (the default: durable steps, sleeps and retries) or `long` (job mode: one long call).
public enum JobMode: String, Codable, Sendable {
  case steps, long
}

/// The options of ``JobsClient/start(_:payload:options:)``.
public struct JobStartOptions: Sendable, Equatable {
  /// The same job and key start one run only; a repeat returns the first run with `duplicate` set.
  public var idempotencyKey: String?
  /// Start after this many seconds.
  public var delay: Int?
  /// Start at this time.
  public var runAt: Date?
  /// Attempts per step before the run fails (default 5; for long runs, attempts after an interruption, default 1).
  public var maxAttempts: Int?
  /// `.long`: job mode, for a function wrapped in `longJob()`.
  public var mode: JobMode?

  public init(
    idempotencyKey: String? = nil, delay: Int? = nil, runAt: Date? = nil, maxAttempts: Int? = nil, mode: JobMode? = nil
  ) {
    self.idempotencyKey = idempotencyKey
    self.delay = delay
    self.runAt = runAt
    self.maxAttempts = maxAttempts
    self.mode = mode
  }
}

/// One step of a run.
public struct JobStep: Decodable, Sendable, Equatable {
  public let name: String
  /// `step` or `sleep`.
  public let kind: String
  public let status: String
  public let output: AnyJSON?
  public let error: String?
  public let attempts: Int
  public let wakeAt: String?

  enum CodingKeys: String, CodingKey {
    case name, kind, status, output, error, attempts
    case wakeAt = "wake_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "step"
    status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    output = try c.decodeIfPresent(AnyJSON.self, forKey: .output)
    error = try c.decodeIfPresent(String.self, forKey: .error)
    attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    wakeAt = try c.decodeIfPresent(String.self, forKey: .wakeAt)
  }
}

/// A run of a job.
public struct JobRun: Decodable, Sendable, Equatable {
  public let id: String
  public let job: String
  public let mode: JobMode
  public let status: JobStatus
  public let payload: AnyJSON
  public let result: AnyJSON?
  public let error: String?
  public let attempt: Int
  public let maxAttempts: Int
  public let idempotencyKey: String?
  public let runAt: String?
  public let createdAt: String?
  public let startedAt: String?
  public let finishedAt: String?
  /// ``JobsClient/get(_:)``: the steps of a steps run.
  public let steps: [JobStep]?
  /// Long runs: progress 0 to 1, the last progress message, billed seconds and the last checkpoint.
  public let progress: Double?
  public let message: String?
  public let seconds: Double?
  public let checkpoint: AnyJSON?
  /// ``JobsClient/start(_:payload:options:)``: true when the idempotency key had started a run already.
  public let duplicate: Bool?

  enum CodingKeys: String, CodingKey {
    case id, job, mode, status, payload, result, error, attempt, steps, progress, message, seconds, checkpoint, duplicate
    case maxAttempts = "max_attempts"
    case idempotencyKey = "idempotency_key"
    case runAt = "run_at"
    case createdAt = "created_at"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    job = try c.decode(String.self, forKey: .job)
    mode = try c.decodeIfPresent(JobMode.self, forKey: .mode) ?? .steps
    status = try c.decode(JobStatus.self, forKey: .status)
    payload = try c.decodeIfPresent(AnyJSON.self, forKey: .payload) ?? .object([:])
    result = try c.decodeIfPresent(AnyJSON.self, forKey: .result)
    error = try c.decodeIfPresent(String.self, forKey: .error)
    attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
    maxAttempts = try c.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? 0
    idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    runAt = try c.decodeIfPresent(String.self, forKey: .runAt)
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
    finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
    steps = try c.decodeIfPresent([JobStep].self, forKey: .steps)
    progress = try c.decodeIfPresent(Double.self, forKey: .progress)
    message = try c.decodeIfPresent(String.self, forKey: .message)
    seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
    checkpoint = try c.decodeIfPresent(AnyJSON.self, forKey: .checkpoint)
    duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate)
  }

  /// The result decoded as `T` (nil while the run has no result).
  public func result<T: Decodable>(as: T.Type) throws -> T? {
    guard let result, result != .null else { return nil }
    return try result.decode(as: T.self)
  }
}

/// One log line of a long run.
public struct JobLogLine: Decodable, Sendable, Equatable {
  public let seq: Int
  public let at: String
  /// `info`, `warn`, `error` or `debug`.
  public let level: String
  public let line: String
}

/// A page of log lines: pass `next` as `after` for the following ones.
public struct JobLogs: Decodable, Sendable, Equatable {
  public let lines: [JobLogLine]
  public let next: Int
  public let more: Bool
}

private struct JobStartBody: Encodable {
  let job: String
  let payload: AnyJSON
  let idempotencyKey: String?
  let delay: Int?
  let runAt: String?
  let maxAttempts: Int?
  let mode: JobMode?

  enum CodingKeys: String, CodingKey {
    case job, payload, delay, mode
    case idempotencyKey = "idempotency_key"
    case runAt = "run_at"
    case maxAttempts = "max_attempts"
  }
}

private struct JobRunList: Decodable { let runs: [JobRun] }

/// Background job runs. Use the one on ``StitchClient/jobs`` (a client made with the service key).
///
/// ```swift
/// let run = try await admin.jobs.start("onboarding", payload: ["user_id": .string(id)],
///                                      options: JobStartOptions(idempotencyKey: "onboarding:\(id)"))
/// let now = try await admin.jobs.get(run.id)
/// ```
public final class JobsClient: Sendable {
  public typealias Fetch = CrashesClient.Fetch

  let http: ServiceHTTP

  init(url: URL, headers: [String: String], fetch: Fetch? = nil) {
    http = ServiceHTTP(url: url, headers: headers, fetch: fetch)
  }

  func setFetch(_ fetch: @escaping Fetch) { http.setFetch(fetch) }

  /// Starts a run of a job (the Edge Function with this name).
  @discardableResult
  public func start(_ job: String, payload: JSONObject = [:], options: JobStartOptions = JobStartOptions()) async throws
    -> JobRun
  {
    let body = JobStartBody(
      job: job, payload: .object(payload), idempotencyKey: options.idempotencyKey, delay: options.delay,
      runAt: options.runAt.map(serviceIsoString), maxAttempts: options.maxAttempts, mode: options.mode
    )
    return try await http.send("POST", ["runs"], body: body, as: JobRun.self, error: JobsError.self)
  }

  /// Starts a run with any encodable payload.
  @discardableResult
  public func start(_ job: String, payload: some Encodable & Sendable, options: JobStartOptions = JobStartOptions())
    async throws -> JobRun
  {
    let object: JSONObject
    do {
      object = try jsonObject(from: payload)
    } catch {
      throw JobsError(message: "payload must encode to a JSON object: \(error)", status: 0)
    }
    return try await start(job, payload: object, options: options)
  }

  /// A run with its steps.
  public func get(_ id: String) async throws -> JobRun {
    try await http.send("GET", ["runs", id], as: JobRun.self, error: JobsError.self)
  }

  /// Recent runs, newest first. `before` is a run id, for the next page.
  public func list(job: String? = nil, status: JobStatus? = nil, limit: Int? = nil, before: String? = nil) async throws
    -> [JobRun]
  {
    let query = queryItems([
      ("job", job), ("status", status?.rawValue), ("limit", limit.map(String.init)), ("before", before),
    ])
    return try await http.send("GET", ["runs"], query: query, as: JobRunList.self, error: JobsError.self).runs
  }

  /// Stops a queued, running or sleeping run. A step that is running finishes, but its result is not used.
  @discardableResult
  public func cancel(_ id: String) async throws -> JobRun {
    try await http.send("POST", ["runs", id, "cancel"], body: JSONObject(), as: JobRun.self, error: JobsError.self)
  }

  /// Runs a failed or cancelled run again from the step that failed (finished steps are kept).
  @discardableResult
  public func retry(_ id: String) async throws -> JobRun {
    try await http.send("POST", ["runs", id, "retry"], body: JSONObject(), as: JobRun.self, error: JobsError.self)
  }

  /// A long run's log lines after `after` (the `next` of the previous page), oldest first.
  public func logs(_ id: String, after: Int? = nil, limit: Int? = nil) async throws -> JobLogs {
    let query = queryItems([("after", after.map(String.init)), ("limit", limit.map(String.init))])
    return try await http.send("GET", ["runs", id, "logs"], query: query, as: JobLogs.self, error: JobsError.self)
  }
}

import Foundation

#if canImport(OSLog)
  public import OSLog

  /// A StitchLogger implementation that logs to OSLog.
  ///
  /// This logger maps StitchDB log levels to appropriate OSLog levels:
  /// - `.verbose` → `.info`
  /// - `.debug` → `.debug`
  /// - `.warning` → `.notice`
  /// - `.error` → `.error`
  ///
  /// ## Usage
  ///
  /// ```swift
  /// let stitchLogger = OSLogStitchDBLogger()
  ///
  /// // Use with StitchDB client
  /// let stitchdb = StitchClient(
  ///   stitchURL: url,
  ///   stitchKey: key,
  ///   options: .init(global: .init(logger: stitchLogger))
  /// )
  /// ```
  public struct OSLogStitchLogger: StitchLogger {
    private let logger: Logger

    /// Creates a new OSLog-based logger with a provided Logger instance.
    ///
    /// - Parameter logger: The OSLog Logger instance to use for logging.
    public init(
      _ logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "StitchDB")
    ) {
      self.logger = logger
    }

    public func log(message: StitchLogMessage) {
      let logMessage = message.description

      switch message.level {
      case .verbose:
        logger.info("\(logMessage, privacy: .public)")
      case .debug:
        logger.debug("\(logMessage, privacy: .public)")
      case .warning:
        logger.notice("\(logMessage, privacy: .public)")
      case .error:
        logger.error("\(logMessage, privacy: .public)")
      }
    }
  }
#endif

import Foundation
#if canImport(os)
import os
#endif

/// Structured logging on top of Apple's unified logging system.
///
/// Rules: never log file contents, credentials, environment variables or other
/// secrets. Messages are public; file paths go through the `path:` overloads,
/// which mark them private so they are redacted from logs collected off-device.
public struct UpkeepLog: Sendable {
    public static let subsystem = "io.github.akshay6890.Upkeep"

    public static let app = UpkeepLog(category: "app")
    public static let scan = UpkeepLog(category: "scan")
    public static let cleanup = UpkeepLog(category: "cleanup")
    public static let tools = UpkeepLog(category: "tools")
    public static let permissions = UpkeepLog(category: "permissions")

    public let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(category: String) {
        self.category = category
        #if canImport(os)
        self.logger = Logger(subsystem: Self.subsystem, category: category)
        #endif
    }

    public func debug(_ message: String) {
        #if canImport(os)
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    public func info(_ message: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public)")
        #endif
    }

    public func warning(_ message: String) {
        #if canImport(os)
        logger.warning("\(message, privacy: .public)")
        #endif
    }

    public func error(_ message: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public)")
        #endif
    }

    public func debug(_ message: String, path: String) {
        #if canImport(os)
        logger.debug("\(message, privacy: .public) \(path, privacy: .private)")
        #endif
    }

    public func info(_ message: String, path: String) {
        #if canImport(os)
        logger.info("\(message, privacy: .public) \(path, privacy: .private)")
        #endif
    }

    public func warning(_ message: String, path: String) {
        #if canImport(os)
        logger.warning("\(message, privacy: .public) \(path, privacy: .private)")
        #endif
    }

    public func error(_ message: String, path: String) {
        #if canImport(os)
        logger.error("\(message, privacy: .public) \(path, privacy: .private)")
        #endif
    }
}

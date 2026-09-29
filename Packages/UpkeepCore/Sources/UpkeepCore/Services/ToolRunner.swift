import Foundation

public struct ToolOutput: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum ToolError: Error, Equatable, Sendable, CustomStringConvertible {
    case notInstalled(String)
    case untrustedExecutable(String)
    case launchFailed(String)
    case failed(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .notInstalled(let tool): return "\(tool) is not installed."
        case .untrustedExecutable(let path): return "Refused to run \(path): it is writable by other users."
        case .launchFailed(let message): return "Couldn't start the tool: \(message)"
        case .failed(let message): return message
        case .invalidArgument(let value): return "Invalid argument: \(value)"
        }
    }
}

/// Runs external tools. Arguments are always passed as an array to the executable
/// directly (never through a shell), so paths or names can't be interpreted as commands.
public protocol ToolRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ToolOutput
}

public struct ProcessToolRunner: ToolRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ToolOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? "/", isDirectory: true)
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ToolError.launchFailed(error.localizedDescription))
                    return
                }

                let timedOut = LockedFlag()
                let deadline = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

                // Drain both pipes concurrently so a chatty tool can't block on a full pipe.
                let group = DispatchGroup()
                let outBox = DataBox()
                let errBox = DataBox()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()
                deadline.cancel()

                continuation.resume(returning: ToolOutput(
                    exitCode: process.terminationStatus,
                    standardOutput: String(decoding: outBox.data, as: UTF8.self),
                    standardError: String(decoding: errBox.data, as: UTF8.self),
                    timedOut: timedOut.value
                ))
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

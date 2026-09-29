import Foundation

public struct SimulatorDevice: Sendable, Equatable, Decodable {
    public let udid: String
    public let name: String
    public let isAvailable: Bool
    public let availabilityError: String?
    public let dataPath: String?
    public let state: String?
}

public enum SimctlParser {
    private struct DeviceList: Decodable {
        let devices: [String: [SimulatorDevice]]
    }

    /// Parses `xcrun simctl list devices --json`, returning devices with their runtime identifier.
    public static func parseDevices(_ json: Data) throws -> [(runtime: String, device: SimulatorDevice)] {
        let list = try JSONDecoder().decode(DeviceList.self, from: json)
        return list.devices
            .flatMap { runtime, devices in devices.map { (runtime: runtime, device: $0) } }
            .sorted { $0.device.name < $1.device.name }
    }

    /// Makes a runtime identifier readable: "com.apple.CoreSimulator.SimRuntime.iOS-17-0" → "iOS 17.0".
    public static func runtimeDisplayName(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return identifier }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    public static func isValidUDID(_ udid: String) -> Bool {
        UUID(uuidString: udid) != nil
    }
}

public struct SimulatorService: Sendable {
    public let locator: ToolLocator
    public let runner: ToolRunning

    public init(locator: ToolLocator, runner: ToolRunning) {
        self.locator = locator
        self.runner = runner
    }

    /// `simctl` ships with Xcode. Invoking `xcrun` without Xcode can trigger the
    /// Command Line Tools installer, so only proceed when an Xcode app is present.
    public func isAvailable() -> Bool {
        let fs = locator.fileSystem
        let hasXcode = locator.environment.xcodeApplicationCandidates.contains { fs.exists($0) }
        return hasXcode && fs.exists(locator.environment.simulatorDevices) && locator.locate(.xcrun) != nil
    }

    /// `xcrun` resolves tools through `xcode-select`, which often points at the Command
    /// Line Tools (no `simctl`) even when Xcode is installed. Point it at Xcode directly.
    var xcrunEnvironment: [String: String]? {
        guard let xcrun = locator.locate(.xcrun) else { return nil }
        var extra: [String: String] = [:]
        let fs = locator.fileSystem
        if let xcode = locator.environment.xcodeApplicationCandidates.first(where: { fs.exists($0) }) {
            let developer = xcode.appendingPathComponent("Contents/Developer", isDirectory: true)
            if fs.exists(developer) { extra["DEVELOPER_DIR"] = developer.path }
        }
        return locator.toolEnvironment(for: xcrun, extra: extra)
    }

    public func listDevices() async throws -> [(runtime: String, device: SimulatorDevice)] {
        guard let xcrun = locator.locate(.xcrun), let environment = xcrunEnvironment else {
            throw ToolError.notInstalled("xcrun")
        }
        let output = try await runner.run(
            xcrun, arguments: ["simctl", "list", "devices", "--json"],
            environment: environment, timeout: 60
        )
        guard output.succeeded else {
            if Self.isMissingSimctl(output) { throw ToolError.notInstalled("simctl") }
            throw ToolError.failed(HomebrewService.failureMessage("simctl list", output))
        }
        return try SimctlParser.parseDevices(Data(output.standardOutput.utf8))
    }

    static func isMissingSimctl(_ output: ToolOutput) -> Bool {
        let text = output.standardError + output.standardOutput
        return text.contains("unable to find utility") || text.contains("not a developer tool")
    }

    public func deleteDevice(udid: String) async throws {
        guard SimctlParser.isValidUDID(udid) else { throw ToolError.invalidArgument(udid) }
        guard let xcrun = locator.locate(.xcrun) else { throw ToolError.notInstalled("xcrun") }
        let output = try await runner.run(
            xcrun, arguments: ["simctl", "delete", udid],
            environment: xcrunEnvironment ?? locator.toolEnvironment(for: xcrun), timeout: 300
        )
        guard output.succeeded else {
            throw ToolError.failed(HomebrewService.failureMessage("simctl delete", output))
        }
    }
}

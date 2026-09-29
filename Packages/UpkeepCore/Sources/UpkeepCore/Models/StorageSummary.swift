import Foundation

public struct StorageSummary: Codable, Hashable, Sendable {
    public let totalCapacity: Int64
    /// Space available for important usage (includes purgeable space on APFS when known).
    public let availableCapacity: Int64
    public let volumeName: String?

    public init(totalCapacity: Int64, availableCapacity: Int64, volumeName: String?) {
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.volumeName = volumeName
    }

    public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    public var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(usedCapacity) / Double(totalCapacity)
    }

    /// Available space if `bytes` were freed, capped at total capacity.
    public func projectedAvailable(afterFreeing bytes: Int64) -> Int64 {
        min(totalCapacity, availableCapacity + max(0, bytes))
    }
}

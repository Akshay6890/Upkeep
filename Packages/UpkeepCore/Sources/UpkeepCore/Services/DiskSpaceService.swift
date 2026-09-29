import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol DiskSpaceProviding: Sendable {
    func storageSummary(for url: URL) throws -> StorageSummary
}

/// Reads volume capacity with native APIs (URL resource values on macOS).
public struct DiskSpaceService: DiskSpaceProviding {
    public init() {}

    public func storageSummary(for url: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> StorageSummary {
        #if os(macOS)
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeLocalizedNameKey,
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        // "Important usage" includes purgeable space macOS will free on demand;
        // it matches what Finder and System Settings show as available.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        return StorageSummary(
            totalCapacity: total,
            availableCapacity: important > 0 ? important : plain,
            volumeName: values.volumeLocalizedName
        )
        #else
        var info = statvfs()
        guard statvfs(url.path, &info) == 0 else {
            throw FileSystemError.from(errno: errno, path: url.path)
        }
        let blockSize = Int64(info.f_frsize)
        return StorageSummary(
            totalCapacity: Int64(info.f_blocks) * blockSize,
            availableCapacity: Int64(info.f_bavail) * blockSize,
            volumeName: nil
        )
        #endif
    }
}

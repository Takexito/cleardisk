import Foundation
import os
import Shared

/// Serializes DiskMonitor state to a shared JSON file readable by the Widget Extension.
/// Becomes a no-op when the App Group container is unavailable (unsigned builds).
enum WidgetDataWriter {
    private static let logger = Logger(subsystem: "com.cleardisk", category: "WidgetDataWriter")
    private static let maxTopCaches = 10

    /// Writes current DiskMonitor state to the shared App Group container.
    /// - Returns: `true` if data was written successfully, `false` otherwise.
    @discardableResult
    static func write(from monitor: DiskMonitor) -> Bool {
        guard let url = SharedPaths.widgetDataURL() else {
            return false
        }

        let topCaches = monitor.devCaches
            .sorted { $0.size > $1.size }
            .prefix(maxTopCaches)
            .map { cache in
                CacheSummary(
                    name: cache.name,
                    sizeBytes: cache.size,
                    icon: cache.icon,
                    riskLevel: cache.riskLevel,
                    category: cache.group ?? "Other"
                )
            }

        let data = WidgetData(
            timestamp: Date(),
            totalSpaceBytes: monitor.totalSpace,
            freeSpaceBytes: monitor.freeSpace,
            usedSpaceBytes: monitor.usedSpace,
            usedPercentage: monitor.usedPercentage,
            totalCleanableBytes: monitor.totalCleanable,
            safeCleanableBytes: monitor.safeCleanable,
            riskyCleanableBytes: monitor.riskyCleanable,
            topCaches: Array(topCaches),
            forecastDaysUntilFull: monitor.forecastDaysUntilFull,
            dailyGrowthRateBytes: monitor.dailyGrowthRate,
            totalSavedAllTimeBytes: monitor.totalSavedAllTime
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: url, options: .atomic)
            logger.info("Widget data written (\(jsonData.count) bytes)")
            return true
        } catch {
            logger.error("Failed to write widget data: \(error.localizedDescription)")
            return false
        }
    }
}

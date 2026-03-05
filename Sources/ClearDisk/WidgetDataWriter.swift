import Foundation
import os
import ClearDiskShared

// MARK: - Widget Data Writer
// Serializes DiskMonitor state to JSON for widget extension consumption

enum WidgetDataWriter {
    private static let logger = Logger(subsystem: "com.cleardisk", category: "WidgetDataWriter")
    private static let topCacheCount = 8

    /// Write widget data derived from current DiskMonitor state.
    /// Must be called on the main thread after scan completes (reads @Published properties).
    /// - Parameters:
    ///   - monitor: The DiskMonitor with populated scan results
    ///   - overrideURL: Optional URL for testing; defaults to SharedPaths.widgetDataURL()
    static func write(from monitor: DiskMonitor, to overrideURL: URL? = nil) {
        guard let url = overrideURL ?? SharedPaths.widgetDataURL() else {
            logger.info("Widget data write skipped — no App Group container available")
            return
        }

        let topCaches = monitor.devCaches
            .sorted { $0.size > $1.size }
            .prefix(topCacheCount)
            .map { cache in
                CacheSummary(
                    name: cache.name,
                    sizeBytes: cache.size,
                    icon: cache.icon,
                    riskLevel: cache.riskLevel,
                    category: cache.group ?? categoryForCache(cache.name)
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

        DispatchQueue.global(qos: .utility).async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(data)
                try jsonData.write(to: url, options: .atomic)
                logger.debug("Widget data written to \(url.path)")
            } catch {
                logger.error("Failed to write widget data: \(error.localizedDescription)")
            }
        }
    }

    /// Derive a category for caches that have no explicit group
    private static func categoryForCache(_ name: String) -> String {
        if name.contains("Docker") { return "Containers" }
        if name.contains("npm") || name.contains("Yarn") || name.contains("pnpm") || name.contains("Bun") { return "JavaScript" }
        if name.contains("pip") || name.contains("Conda") { return "Python" }
        if name.contains("Gradle") || name.contains("Maven") || name.contains("Android") { return "Java/Android" }
        if name.contains("Go ") { return "Go" }
        if name.contains("Rust") || name.contains("Cargo") { return "Rust" }
        if name.contains("Homebrew") { return "System Tools" }
        if name.contains("CocoaPods") || name.contains("Carthage") { return "iOS/macOS" }
        if name.contains("Terraform") { return "Infrastructure" }
        if name.contains("Composer") { return "PHP" }
        if name.contains("Flutter") || name.contains("Pub") { return "Flutter" }
        if name.contains("JetBrains") { return "IDEs" }
        return "Other"
    }
}

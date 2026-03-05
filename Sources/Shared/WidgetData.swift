import Foundation

/// Data shared between the main ClearDisk app and the Widget Extension.
/// Written by the app after each scan, read by the widget's TimelineProvider.
public struct WidgetData: Codable {
    public let timestamp: Date

    // Disk overview
    public let totalSpaceBytes: Int64
    public let freeSpaceBytes: Int64
    public let usedSpaceBytes: Int64
    public let usedPercentage: Int

    // Cache summary
    public let totalCleanableBytes: Int64
    public let safeCleanableBytes: Int64
    public let riskyCleanableBytes: Int64

    // Top caches by size (for medium/large widget)
    public let topCaches: [CacheSummary]

    // Forecast
    public let forecastDaysUntilFull: Int?
    public let dailyGrowthRateBytes: Int64

    // Savings
    public let totalSavedAllTimeBytes: Int64

    public init(
        timestamp: Date,
        totalSpaceBytes: Int64,
        freeSpaceBytes: Int64,
        usedSpaceBytes: Int64,
        usedPercentage: Int,
        totalCleanableBytes: Int64,
        safeCleanableBytes: Int64,
        riskyCleanableBytes: Int64,
        topCaches: [CacheSummary],
        forecastDaysUntilFull: Int?,
        dailyGrowthRateBytes: Int64,
        totalSavedAllTimeBytes: Int64
    ) {
        self.timestamp = timestamp
        self.totalSpaceBytes = totalSpaceBytes
        self.freeSpaceBytes = freeSpaceBytes
        self.usedSpaceBytes = usedSpaceBytes
        self.usedPercentage = usedPercentage
        self.totalCleanableBytes = totalCleanableBytes
        self.safeCleanableBytes = safeCleanableBytes
        self.riskyCleanableBytes = riskyCleanableBytes
        self.topCaches = topCaches
        self.forecastDaysUntilFull = forecastDaysUntilFull
        self.dailyGrowthRateBytes = dailyGrowthRateBytes
        self.totalSavedAllTimeBytes = totalSavedAllTimeBytes
    }
}

/// Summary of a single cache entry for widget display.
public struct CacheSummary: Codable {
    public let name: String        // e.g. "Xcode DerivedData"
    public let sizeBytes: Int64
    public let icon: String        // SF Symbol name
    public let riskLevel: String   // "safe", "caution", "risky"
    public let category: String    // group name: "Xcode", "Package Manager", etc.

    public init(name: String, sizeBytes: Int64, icon: String, riskLevel: String, category: String) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.icon = icon
        self.riskLevel = riskLevel
        self.category = category
    }
}

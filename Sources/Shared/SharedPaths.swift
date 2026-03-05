import Foundation
import os

// MARK: - Shared Paths
// App Group container path resolution for data sharing between app and widget

public enum SharedPaths {
    public static let appGroupIdentifier = "group.com.cleardisk.shared"
    public static let widgetDataFilename = "widget-data.json"

    private static let logger = Logger(subsystem: "com.cleardisk", category: "SharedPaths")

    /// Resolves the URL for the widget data JSON file in the App Group container.
    /// Returns nil if App Group is not available (unsigned build or misconfigured entitlements).
    public static func widgetDataURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            logger.warning("App Group container unavailable — check entitlements and code signing")
            return nil
        }
        return containerURL.appendingPathComponent(widgetDataFilename)
    }
}

import Foundation
import os

/// Shared paths and constants for data exchange between the main app and Widget Extension.
/// Uses App Group container as the sole data-sharing mechanism.
public enum SharedPaths {
    public static let appGroupIdentifier = "group.com.cleardisk.shared"

    private static let logger = Logger(subsystem: "com.cleardisk", category: "SharedPaths")

    /// Returns the URL for the shared widget data JSON file inside the App Group container.
    /// Returns `nil` if the container is unavailable (unsigned build or missing entitlements).
    public static func widgetDataURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            logger.warning("App Group container unavailable — widget data sharing disabled. Check entitlements and code signing.")
            return nil
        }
        return containerURL.appendingPathComponent("widget-data.json")
    }

    /// Shared JSON encoder configured for widget data. Both writer and reader must use the same config.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Shared JSON decoder configured for widget data. Both writer and reader must use the same config.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Foundation

public enum AppBundleNameMigrator {
    public static let preferredBundleName = "Sub Buddy.app"
    public static let legacyBundleNames: Set<String> = [
        "AI看剧伴侣.app",
        "AI Viewing Companion.app",
        "MKV Subtitle Translator.app"
    ]

    public static func destinationURL(
        for bundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let standardizedURL = bundleURL.standardizedFileURL
        guard legacyBundleNames.contains(standardizedURL.lastPathComponent) else { return nil }

        let destination = standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent(preferredBundleName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }
        return destination
    }

    public static func obsoleteLegacyBundleURLs(
        alongside currentBundleURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let currentURL = currentBundleURL.standardizedFileURL
        guard currentURL.lastPathComponent == preferredBundleName,
              let currentMetadata = metadata(at: currentURL),
              let currentBuild = currentMetadata.buildNumber else {
            return []
        }

        return legacyBundleNames.compactMap { legacyName in
            let legacyURL = currentURL.deletingLastPathComponent()
                .appendingPathComponent(legacyName, isDirectory: true)
            guard fileManager.fileExists(atPath: legacyURL.path),
                  let legacyMetadata = metadata(at: legacyURL),
                  legacyMetadata.identifier == currentMetadata.identifier,
                  let legacyBuild = legacyMetadata.buildNumber,
                  legacyBuild <= currentBuild else {
                return nil
            }
            return legacyURL
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func preferredBundleShouldReplaceLegacy(
        legacyBundleURL: URL,
        preferredBundleURL: URL
    ) -> Bool {
        guard let legacy = metadata(at: legacyBundleURL),
              let preferred = metadata(at: preferredBundleURL),
              legacy.identifier == preferred.identifier,
              let legacyBuild = legacy.buildNumber,
              let preferredBuild = preferred.buildNumber else {
            return false
        }
        return preferredBuild >= legacyBuild
    }

    @discardableResult
    public static func migrateIfNeeded(
        bundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let destination = destinationURL(for: bundleURL, fileManager: fileManager) else {
            return nil
        }
        try fileManager.moveItem(at: bundleURL.standardizedFileURL, to: destination)
        return destination
    }

    private static func metadata(at bundleURL: URL) -> (identifier: String, buildNumber: Int?)? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String else {
            return nil
        }
        let rawBuild = dictionary["CFBundleVersion"]
        let buildNumber: Int?
        if let value = rawBuild as? String {
            buildNumber = Int(value)
        } else if let value = rawBuild as? NSNumber {
            buildNumber = value.intValue
        } else {
            buildNumber = nil
        }
        return (identifier, buildNumber)
    }
}

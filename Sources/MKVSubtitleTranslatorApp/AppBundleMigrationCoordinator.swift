import AppKit
import MKVSubtitleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let originalURL = Bundle.main.bundleURL
        if originalURL.lastPathComponent == AppBundleNameMigrator.preferredBundleName {
            removeObsoleteLegacyCopies(alongside: originalURL)
            return
        }

        let preferredURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(AppBundleNameMigrator.preferredBundleName, isDirectory: true)
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            if AppBundleNameMigrator.preferredBundleShouldReplaceLegacy(
                legacyBundleURL: originalURL,
                preferredBundleURL: preferredURL
            ) {
                relaunch(at: preferredURL, trashAfterLaunch: originalURL)
            } else if trash(preferredURL),
                      let migratedURL = try? AppBundleNameMigrator.migrateIfNeeded(bundleURL: originalURL) {
                relaunch(at: migratedURL)
            }
            return
        }

        guard let migratedURL = try? AppBundleNameMigrator.migrateIfNeeded(bundleURL: originalURL) else {
            return
        }
        relaunch(at: migratedURL)
    }

    private func removeObsoleteLegacyCopies(alongside currentURL: URL) {
        for legacyURL in AppBundleNameMigrator.obsoleteLegacyBundleURLs(alongside: currentURL) {
            _ = trash(legacyURL)
        }
    }

    private func relaunch(at migratedURL: URL, trashAfterLaunch legacyURL: URL? = nil) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: migratedURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                if let legacyURL {
                    _ = self.trash(legacyURL)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func trash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}

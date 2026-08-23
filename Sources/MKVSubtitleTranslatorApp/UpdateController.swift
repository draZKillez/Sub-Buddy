import Foundation
import Sparkle
import MKVSubtitleCore

@MainActor
final class UpdateController: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    let isConfigured: Bool

    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = feed.hasPrefix("https://") &&
            !feed.contains("OWNER/REPOSITORY") &&
            !key.isEmpty
        updaterController = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        isConfigured && updaterController.updater.canCheckForUpdates
    }

    var configurationMessage: String {
        AppInterfaceLanguage.localized(isConfigured
            ? "使用 GitHub Releases 安全更新"
            : "开发包尚未配置 GitHub 仓库；Release 构建会自动注入更新源")
    }

    var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)):
            return "\(version) (\(build))"
        case let (.some(version), .none):
            return version
        default:
            return "开发版"
        }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        updaterController.checkForUpdates(nil)
    }
}

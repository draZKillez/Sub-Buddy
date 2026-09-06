#if DEBUG
import AppKit
import MKVSubtitleCore

/// Local visual regression harness. Excluded entirely from distributed builds.
@MainActor
enum WorkspaceSnapshot {
    static var path: String? { ProcessInfo.processInfo.environment["SUBBUDDY_UI_SNAPSHOT"] }
    static var step: Int { Int(ProcessInfo.processInfo.environment["SUBBUDDY_UI_STEP"] ?? "0") ?? 0 }

    static func prepare(_ model: AppViewModel) {
        guard step > 0 else { return }
        let file = URL(fileURLWithPath: "/Movies/A Beautiful Journey.mkv")
        model.selectedFile = file
        model.movie = MovieInfo(originalTitle: "A Beautiful Journey", year: 2026)
        model.mediaInfo = MediaInfo(fileURL: file, containerTitle: "A Beautiful Journey", durationSeconds: 5420, subtitleTracks: [
            SubtitleTrack(streamIndex: 2, codec: "subrip", language: "eng", title: "English", isDefault: true, isForced: false, isSDH: false, isText: true),
            SubtitleTrack(streamIndex: 3, codec: "subrip", language: "eng", title: "English SDH", isDefault: false, isForced: false, isSDH: true, isText: true)
        ])
        model.selectedTrackIndex = 2
        model.codexStatus = .loggedIn
    }

    static func captureWhenReady() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first, let path else { NSApp.terminate(nil); return }
            let dark = ProcessInfo.processInfo.environment["SUBBUDDY_UI_DARK"] == "1"
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: 1150, height: 900))
            try? await Task.sleep(for: .seconds(1))
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
#endif

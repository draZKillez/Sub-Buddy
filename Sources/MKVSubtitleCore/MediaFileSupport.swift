import Foundation

/// Formats covered by the bundled macOS demuxers and subtitle integration tests.
/// A supported container may still contain no subtitles, DRM, or an unsupported codec.
public enum MediaFileSupport {
    public static let extensions = ["mkv", "mp4", "m4v", "mov", "webm"]
    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }
    public static func canRemux(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mkv"
    }
}

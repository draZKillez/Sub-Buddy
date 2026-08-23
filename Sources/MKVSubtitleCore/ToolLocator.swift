import Foundation

public struct ToolPaths: Equatable, Sendable {
    public let ffmpeg: URL?
    public let ffprobe: URL?
    public let codex: URL?
    public let homebrew: URL?
    public let mkvextract: URL?
    public let bitmapSubtitleDecoder: URL?

    public init(ffmpeg: URL?, ffprobe: URL?, codex: URL?, homebrew: URL? = nil, mkvextract: URL? = nil, bitmapSubtitleDecoder: URL? = nil) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.codex = codex
        self.homebrew = homebrew
        self.mkvextract = mkvextract
        self.bitmapSubtitleDecoder = bitmapSubtitleDecoder
    }
}

public protocol ToolLocating: Sendable {
    func locate() -> ToolPaths
}

public struct ToolLocator: ToolLocating, @unchecked Sendable {
    private let fileManager: FileManager
    private let additionalCodexPaths: [String]
    private let bundleResourceURL: URL?

    public init(
        fileManager: FileManager = .default,
        additionalCodexPaths: [String] = [],
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) {
        self.fileManager = fileManager
        self.additionalCodexPaths = additionalCodexPaths
        self.bundleResourceURL = bundleResourceURL
    }

    public func locate() -> ToolPaths {
        ToolPaths(
            ffmpeg: firstExecutable(bundledToolPaths("ffmpeg") + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]),
            ffprobe: firstExecutable(bundledToolPaths("ffprobe") + ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]),
            codex: firstExecutable(additionalCodexPaths + [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex"
            ]),
            homebrew: firstExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]),
            mkvextract: firstExecutable(["/opt/homebrew/bin/mkvextract", "/usr/local/bin/mkvextract"]),
            bitmapSubtitleDecoder: firstExecutable(bundledToolPaths("mkvbitmapdecode"))
        )
    }

    private func firstExecutable(_ paths: [String]) -> URL? {
        paths.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func bundledToolPaths(_ name: String) -> [String] {
        guard let bundleResourceURL else { return [] }
        return [bundleResourceURL.appendingPathComponent("Tools", isDirectory: true).appendingPathComponent(name).path]
    }
}

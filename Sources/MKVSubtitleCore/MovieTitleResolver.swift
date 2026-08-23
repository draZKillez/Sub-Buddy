import Foundation

public protocol MovieMetadataProvider: Sendable {
    func chineseTitleCandidates(originalTitle: String, year: Int?) async throws -> [String]
}

public struct EmptyMovieMetadataProvider: MovieMetadataProvider {
    public init() {}
    public func chineseTitleCandidates(originalTitle: String, year: Int?) async throws -> [String] { [] }
}

public struct MovieTitleResolver: Sendable {
    public init() {}

    public func resolve(fileURL: URL, containerTitle: String?) -> MovieInfo {
        let raw = nonEmpty(containerTitle) ?? fileURL.deletingPathExtension().lastPathComponent
        let year = extractYear(raw)
        var title = raw

        title = title.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)

        let releaseToken = "(?i)(?:^|\\s)(?:19\\d{2}|20\\d{2}|2160p|1080p|720p|480p|4k|uhd|blu-?ray|bdrip|br-?rip|web[ .-]?dl|webrip|hdr10\\+?|hdr|dv|dolby[ .-]?vision|remux|x264|x265|h[ .-]?264|h[ .-]?265|hevc|avc|aac(?:[ .-]?\\d(?:\\.\\d)?)?|dts(?:[ .-]?hd)?|truehd|atmos|ddp?(?:[ .-]?\\d(?:\\.\\d)?)?|flac|proper|repack|extended|directors?[ .-]?cut|multi)(?:\\s|$).*$"
        title = title.replacingOccurrences(of: releaseToken, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: "(?i)[ ._-]+(?:YTS|RARBG|FGT|NTb|EVO|AMZN|NF|HMAX|DSNP)$", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))

        if title.isEmpty {
            title = fileURL.deletingPathExtension().lastPathComponent
        }
        return MovieInfo(originalTitle: title, year: year)
    }

    public func resolve(
        fileURL: URL,
        containerTitle: String?,
        metadataProvider: MovieMetadataProvider
    ) async -> MovieInfo {
        var info = resolve(fileURL: fileURL, containerTitle: containerTitle)
        info.chineseTitleCandidates = (try? await metadataProvider.chineseTitleCandidates(
            originalTitle: info.originalTitle,
            year: info.year
        )) ?? []
        return info
    }

    private func extractYear(_ value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\d)(19\\d{2}|20\\d{2})(?!\\d)"),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

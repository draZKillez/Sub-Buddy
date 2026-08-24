import Foundation

public protocol MovieMetadataProvider: Sendable {
    func chineseTitleCandidates(originalTitle: String, year: Int?) async throws -> [String]
}

public struct EmptyMovieMetadataProvider: MovieMetadataProvider {
    public init() {}
    public func chineseTitleCandidates(originalTitle: String, year: Int?) async throws -> [String] { [] }
}

public struct MovieTitleResolver: Sendable {
    private static let yearExpression = try! NSRegularExpression(
        pattern: "(?<!\\d)(19\\d{2}|20\\d{2})(?!\\d)"
    )
    private static let separatorExpression = try! NSRegularExpression(pattern: "[._]")
    private static let squareBracketExpression = try! NSRegularExpression(pattern: "\\[[^\\]]*\\]")
    private static let parenthesisExpression = try! NSRegularExpression(pattern: "\\([^)]*\\)")
    private static let releaseExpression = try! NSRegularExpression(
        pattern: "(?:^|\\s)(?:19\\d{2}|20\\d{2}|2160p|1080p|720p|480p|4k|uhd|blu-?ray|bdrip|br-?rip|web[ .-]?dl|webrip|hdr10\\+?|hdr|dv|dolby[ .-]?vision|remux|x264|x265|h[ .-]?264|h[ .-]?265|hevc|avc|aac(?:[ .-]?\\d(?:\\.\\d)?)?|dts(?:[ .-]?hd)?|truehd|atmos|ddp?(?:[ .-]?\\d(?:\\.\\d)?)?|flac|proper|repack|extended|directors?[ .-]?cut|multi)(?:\\s|$).*$",
        options: [.caseInsensitive]
    )
    private static let releaseGroupExpression = try! NSRegularExpression(
        pattern: "[ ._-]+(?:YTS|RARBG|FGT|NTb|EVO|AMZN|NF|HMAX|DSNP)$",
        options: [.caseInsensitive]
    )
    private static let whitespaceExpression = try! NSRegularExpression(pattern: "\\s+")

    public init() {}

    public func resolve(fileURL: URL, containerTitle: String?) -> MovieInfo {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let raw = nonEmpty(containerTitle) ?? fileName
        let year = extractYear(raw) ?? extractYear(fileName)
        var title = raw

        title = replacingMatches(in: title, using: Self.separatorExpression, with: " ")
        title = replacingMatches(in: title, using: Self.squareBracketExpression, with: " ")
        title = replacingMatches(in: title, using: Self.parenthesisExpression, with: " ")
        title = replacingMatches(in: title, using: Self.releaseExpression, with: " ")
        title = replacingMatches(in: title, using: Self.releaseGroupExpression, with: "")
        title = replacingMatches(in: title, using: Self.whitespaceExpression, with: " ")
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
        guard let match = Self.yearExpression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }

    private func replacingMatches(
        in value: String,
        using expression: NSRegularExpression,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

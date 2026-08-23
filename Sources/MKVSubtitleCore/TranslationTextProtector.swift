import Foundation

public struct ProtectedTranslationText: Equatable, Sendable {
    public let sourceText: String
    private let replacements: [(marker: String, original: String)]

    fileprivate init(sourceText: String, replacements: [(marker: String, original: String)]) {
        self.sourceText = sourceText
        self.replacements = replacements
    }

    public func restore(_ translatedText: String) throws -> String {
        var result = translatedText
        for replacement in replacements {
            let occurrences = result.components(separatedBy: replacement.marker).count - 1
            guard occurrences == 1 else {
                throw AppError.invalidTranslation("译文未完整保留字幕换行或样式标签。")
            }
            result = result.replacingOccurrences(of: replacement.marker, with: replacement.original)
        }
        return result
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceText == rhs.sourceText &&
            lhs.replacements.map { [$0.marker, $0.original] } == rhs.replacements.map { [$0.marker, $0.original] }
    }
}

public struct TranslationTextProtector: Sendable {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:</?[^>\n]+>|\{\\[^}\n]*\}|\r\n|\n|\r)"#
    )

    public init() {}

    public func protect(_ text: String) -> ProtectedTranslationText {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = Self.expression.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return ProtectedTranslationText(sourceText: text, replacements: [])
        }

        let mutable = NSMutableString(string: text)
        var replacements: [(marker: String, original: String)] = []
        replacements.reserveCapacity(matches.count)
        for (index, match) in matches.enumerated() {
            let original = (text as NSString).substring(with: match.range)
            replacements.append((marker: marker(index), original: original))
        }
        for index in matches.indices.reversed() {
            mutable.replaceCharacters(in: matches[index].range, with: replacements[index].marker)
        }
        return ProtectedTranslationText(sourceText: mutable as String, replacements: replacements)
    }

    private func marker(_ index: Int) -> String {
        "\u{E000}MKVSUB\(index)\u{E001}"
    }
}

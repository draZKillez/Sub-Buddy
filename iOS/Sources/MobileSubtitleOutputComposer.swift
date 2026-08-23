import Foundation

public struct SubtitleOutputComposer: Sendable {
    public init() {}

    public func text(
        chinese: String,
        english: String,
        format: SubtitleFormat,
        mode: SubtitleOutputMode
    ) -> String {
        guard mode == .bilingual else { return chinese }
        let separator = format == .ass ? "\\N" : "\n"
        return chinese + separator + english
    }
}

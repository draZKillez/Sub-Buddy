import Foundation

public struct SubtitleWriter: Sendable {
    public init() {}

    public func string(from document: SubtitleDocument) throws -> String {
        switch document.format {
        case .srt:
            return document.cues.map { cue in
                "\(cue.id)\n\(formatSRT(cue.startMilliseconds)) --> \(formatSRT(cue.endMilliseconds))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case .webVTT:
            let header = document.webVTTHeader ?? "WEBVTT"
            let body = document.cues.map { cue in
                "\(cue.id)\n\(formatVTT(cue.startMilliseconds)) --> \(formatVTT(cue.endMilliseconds))\n\(cue.text)"
            }.joined(separator: "\n\n")
            return "\(header)\n\n\(body)\n"
        case .ass:
            guard let formatFields = document.assFormatFields,
                  let textIndex = formatFields.firstIndex(of: "text"),
                  let startIndex = formatFields.firstIndex(of: "start"),
                  let endIndex = formatFields.firstIndex(of: "end") else {
                throw AppError.parsingFailed("ASS 文档缺少 Events Format 的 Start、End 或 Text 字段。")
            }
            let header = document.assHeader ?? "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
            let dialogues = try document.cues.map { cue -> String in
                guard var fields = cue.assFields, fields.count == formatFields.count - 1 else {
                    throw AppError.parsingFailed("ASS 字幕字段数量不匹配。")
                }
                fields[startIndex > textIndex ? startIndex - 1 : startIndex] = formatASS(cue.startMilliseconds)
                fields[endIndex > textIndex ? endIndex - 1 : endIndex] = formatASS(cue.endMilliseconds)
                fields.insert(cue.text, at: textIndex)
                return "Dialogue: \(fields.joined(separator: ","))"
            }
            let dialogueText = dialogues.joined(separator: "\n")
            let trimmedHeader = header.trimmingCharacters(in: .newlines)
            if trimmedHeader.contains(SubtitleInternalFormat.assDialoguesMarker) {
                return trimmedHeader.replacingOccurrences(
                    of: SubtitleInternalFormat.assDialoguesMarker,
                    with: dialogueText
                ) + "\n"
            }
            return trimmedHeader + "\n" + dialogueText + "\n"
        }
    }

    public func write(_ document: SubtitleDocument, to url: URL) throws {
        try Data(string(from: document).utf8).write(to: url, options: .atomic)
    }

    private func formatSRT(_ milliseconds: Int64) -> String {
        let parts = clockParts(milliseconds)
        return String(format: "%02lld:%02lld:%02lld,%03lld", parts.hours, parts.minutes, parts.seconds, parts.milliseconds)
    }

    private func formatVTT(_ milliseconds: Int64) -> String {
        let parts = clockParts(milliseconds)
        return String(format: "%02lld:%02lld:%02lld.%03lld", parts.hours, parts.minutes, parts.seconds, parts.milliseconds)
    }

    private func formatASS(_ milliseconds: Int64) -> String {
        let parts = clockParts(milliseconds)
        return String(format: "%lld:%02lld:%02lld.%02lld", parts.hours, parts.minutes, parts.seconds, parts.milliseconds / 10)
    }

    private func clockParts(_ value: Int64) -> (hours: Int64, minutes: Int64, seconds: Int64, milliseconds: Int64) {
        let totalSeconds = value / 1_000
        return (totalSeconds / 3_600, (totalSeconds % 3_600) / 60, totalSeconds % 60, value % 1_000)
    }
}

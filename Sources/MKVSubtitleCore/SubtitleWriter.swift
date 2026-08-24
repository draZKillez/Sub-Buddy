import Foundation

public struct SubtitleWriter: Sendable {
    public init() {}

    public func string(from document: SubtitleDocument) throws -> String {
        switch document.format {
        case .srt:
            var output = ""
            output.reserveCapacity(document.cues.count * 96)
            for (index, cue) in document.cues.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                if index > 0 { output.append("\n") }
                output.append("\(cue.id)\n")
                output.append("\(formatSRT(cue.startMilliseconds)) --> \(formatSRT(cue.endMilliseconds))\n")
                output.append(cue.text)
                output.append("\n")
            }
            if document.cues.isEmpty { output.append("\n") }
            return output
        case .webVTT:
            let header = document.webVTTHeader ?? "WEBVTT"
            var output = "\(header)\n\n"
            output.reserveCapacity(output.count + document.cues.count * 96)
            for (index, cue) in document.cues.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                if index > 0 { output.append("\n") }
                output.append("\(cue.id)\n")
                output.append("\(formatVTT(cue.startMilliseconds)) --> \(formatVTT(cue.endMilliseconds))\n")
                output.append(cue.text)
                output.append("\n")
            }
            if document.cues.isEmpty { output.append("\n") }
            return output
        case .ass:
            guard let formatFields = document.assFormatFields,
                  let textIndex = formatFields.firstIndex(of: "text"),
                  let startIndex = formatFields.firstIndex(of: "start"),
                  let endIndex = formatFields.firstIndex(of: "end") else {
                throw AppError.parsingFailed("ASS 文档缺少 Events Format 的 Start、End 或 Text 字段。")
            }
            let header = document.assHeader ?? "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
            var dialogueText = ""
            dialogueText.reserveCapacity(document.cues.count * 128)
            for (index, cue) in document.cues.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                guard var fields = cue.assFields, fields.count == formatFields.count - 1 else {
                    throw AppError.parsingFailed("ASS 字幕字段数量不匹配。")
                }
                fields[startIndex > textIndex ? startIndex - 1 : startIndex] = formatASS(cue.startMilliseconds)
                fields[endIndex > textIndex ? endIndex - 1 : endIndex] = formatASS(cue.endMilliseconds)
                fields.insert(cue.text, at: textIndex)
                if index > 0 { dialogueText.append("\n") }
                dialogueText.append("Dialogue: ")
                dialogueText.append(fields.joined(separator: ","))
            }
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

    public func write(_ document: SubtitleDocument, to url: URL, overwrite: Bool = true) throws {
        let text = try string(from: document)
        try Task.checkCancellation()
        let data = Data(text.utf8)
        if overwrite {
            try data.write(to: url, options: .atomic)
            return
        }

        // NSDataWritingAtomic cannot be combined with
        // NSDataWritingWithoutOverwriting (Foundation raises an Objective-C
        // exception). Fully materialize a unique sibling first, then let
        // FileManager's non-replacing move publish it.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).partial"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: url)
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

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let matroskaVideo = UTType(importedAs: "org.matroska.mkv")
    static let subRipSubtitle = UTType(importedAs: "com.mkvsubtitletranslator.srt")
    static let advancedSubStationAlpha = UTType(importedAs: "com.mkvsubtitletranslator.ass")
    static let pgsSubtitle = UTType(importedAs: "com.mkvsubtitletranslator.sup")
    static let webVTTSubtitle = UTType(importedAs: "org.w3.webvtt")
}

struct SubtitleExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.subRipSubtitle] }
    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

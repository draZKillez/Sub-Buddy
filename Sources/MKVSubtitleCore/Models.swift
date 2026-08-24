import Foundation

public enum AppInterfaceLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case korean = "ko"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"

    public static let preferenceKey = "appInterfaceLanguage"
    private static let localizationBundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: AppInterfaceLanguage.allCases.compactMap { language in
            guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language.rawValue, bundle)
        })
    }()
    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }

    public var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        }
    }

    public static var current: AppInterfaceLanguage {
        let stored = UserDefaults.standard.string(forKey: preferenceKey)
        return stored.flatMap(AppInterfaceLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    public static func localized(_ key: String) -> String {
        localized(key, language: current)
    }

    public static func localized(_ key: String, language: AppInterfaceLanguage) -> String {
        guard language != .simplifiedChinese else { return key }
        if let bundle = localizationBundles[language.rawValue] {
            let translated = bundle.localizedString(forKey: key, value: key, table: nil)
            if translated != key { return translated }
        }
        guard language != .english,
              let englishBundle = localizationBundles[AppInterfaceLanguage.english.rawValue] else { return key }
        return englishBundle.localizedString(forKey: key, value: key, table: nil)
    }

    public static func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: current.locale, arguments: arguments)
    }
}

public enum SubtitleLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case korean = "ko"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"

    private static let aliasTable: [SubtitleLanguage: Set<String>] = [
        .english: ["en", "eng", "english"],
        .simplifiedChinese: ["zh", "zho", "chi", "cmn", "zh-cn", "zh-hans", "chinese"],
        .spanish: ["es", "spa", "spanish"],
        .french: ["fr", "fra", "fre", "french"],
        .german: ["de", "deu", "ger", "german"],
        .japanese: ["ja", "jpn", "japanese"],
        .korean: ["ko", "kor", "korean"],
        .portuguese: ["pt", "por", "portuguese", "pt-br", "pt-pt"],
        .russian: ["ru", "rus", "russian"],
        .arabic: ["ar", "ara", "arabic"]
    ]

    public var id: String { rawValue }

    public var displayName: String {
        AppInterfaceLanguage.localized(interfaceNameKey)
    }

    private var interfaceNameKey: String {
        switch self {
        case .english: return "英语"
        case .simplifiedChinese: return "简体中文"
        case .spanish: return "西班牙语"
        case .french: return "法语"
        case .german: return "德语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .portuguese: return "葡萄牙语"
        case .russian: return "俄语"
        case .arabic: return "阿拉伯语"
        }
    }

    public var promptName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese（简体中文）"
        case .spanish: return "Spanish（西班牙语）"
        case .french: return "French（法语）"
        case .german: return "German（德语）"
        case .japanese: return "Japanese（日语）"
        case .korean: return "Korean（韩语）"
        case .portuguese: return "Portuguese（葡萄牙语）"
        case .russian: return "Russian（俄语）"
        case .arabic: return "Arabic（阿拉伯语）"
        }
    }

    public var iso6392Code: String {
        switch self {
        case .english: return "eng"
        case .simplifiedChinese: return "zho"
        case .spanish: return "spa"
        case .french: return "fra"
        case .german: return "deu"
        case .japanese: return "jpn"
        case .korean: return "kor"
        case .portuguese: return "por"
        case .russian: return "rus"
        case .arabic: return "ara"
        }
    }

    public var outputCode: String {
        switch self {
        case .simplifiedChinese: return "zh"
        default: return rawValue
        }
    }

    public var recognitionLanguage: String {
        switch self {
        case .english: return "en-US"
        case .simplifiedChinese: return "zh-Hans"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .arabic: return "ar-SA"
        }
    }

    public func matches(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let base = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalized
        return aliases.contains(normalized) || aliases.contains(base)
    }

    private var aliases: Set<String> { Self.aliasTable[self] ?? [] }
}

public enum SubtitleFormat: String, Codable, Sendable {
    case srt
    case ass
    case webVTT
}

public enum SubtitleOutputMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case pureChinese
    case bilingual

    public var id: String { rawValue }

    public var displayName: String {
        AppInterfaceLanguage.localized(self == .pureChinese ? "仅译文" : "双语（译文 + 原文）")
    }

    public func trackTitle(sourceLanguage: SubtitleLanguage, targetLanguage: SubtitleLanguage) -> String {
        self == .bilingual
            ? "\(targetLanguage.displayName) + \(sourceLanguage.displayName)"
            : targetLanguage.displayName
    }

    public func sidecarFileSuffix(targetLanguage: SubtitleLanguage) -> String {
        if self == .pureChinese && targetLanguage == .simplifiedChinese { return "" }
        return "_\(targetLanguage.outputCode)" + (self == .bilingual ? "_bilingual" : "")
    }

    public func muxFileSuffix(targetLanguage: SubtitleLanguage) -> String {
        "_\(targetLanguage.outputCode)" + (self == .bilingual ? "_bilingual" : "")
    }
}

public enum DeliveryMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case sidecarSRT
    case muxMKV

    public var id: String { rawValue }

    public var displayName: String {
        AppInterfaceLanguage.localized(self == .sidecarSRT ? "生成独立 SRT" : "重新封装 MKV")
    }
}

public struct SubtitleCue: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var startMilliseconds: Int64
    public var endMilliseconds: Int64
    public var text: String
    public var assFields: [String]?

    public init(
        id: Int,
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String,
        assFields: [String]? = nil
    ) {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.assFields = assFields
    }
}

public struct SubtitleDocument: Codable, Equatable, Sendable {
    public var format: SubtitleFormat
    public var cues: [SubtitleCue]
    public var assHeader: String?
    public var assFormatFields: [String]?
    public var webVTTHeader: String?

    public init(
        format: SubtitleFormat,
        cues: [SubtitleCue],
        assHeader: String? = nil,
        assFormatFields: [String]? = nil,
        webVTTHeader: String? = nil
    ) {
        self.format = format
        self.cues = cues
        self.assHeader = assHeader
        self.assFormatFields = assFormatFields
        self.webVTTHeader = webVTTHeader
    }
}

public struct SubtitleTrack: Codable, Equatable, Sendable, Identifiable {
    private static let sdhTitleExpression = try? NSRegularExpression(
        pattern: #"(?:\bSDH\b|\bhearing[ -]?impaired\b|\bCC\b)"#,
        options: .caseInsensitive
    )

    public var id: Int { streamIndex }
    public let streamIndex: Int
    public let codec: String
    public let language: String
    public let title: String
    public let isDefault: Bool
    public let isForced: Bool
    public let isSDH: Bool
    public let isText: Bool

    public init(
        streamIndex: Int,
        codec: String,
        language: String,
        title: String,
        isDefault: Bool,
        isForced: Bool,
        isSDH: Bool,
        isText: Bool
    ) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isSDH = isSDH
        self.isText = isText
    }

    public var isEnglish: Bool {
        SubtitleLanguage.english.matches(language)
    }

    public static func titleSuggestsSDH(_ title: String) -> Bool {
        guard let expression = sdhTitleExpression else { return false }
        return expression.firstMatch(
            in: title,
            range: NSRange(title.startIndex..., in: title)
        ) != nil
    }

    public func matches(_ selectedLanguage: SubtitleLanguage) -> Bool {
        selectedLanguage.matches(language)
    }

    public var supportsLocalOCR: Bool {
        ["hdmv_pgs_subtitle", "dvd_subtitle"].contains(codec.lowercased())
    }
    public var isPGS: Bool { codec.lowercased() == "hdmv_pgs_subtitle" }
    public var isVobSub: Bool { codec.lowercased() == "dvd_subtitle" }
    public var isProcessable: Bool { isText || supportsLocalOCR }
}

public struct AudioTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { streamIndex }
    public let streamIndex: Int
    public let codec: String
    public let language: String
    public let title: String
    public let channels: Int?
    public let isDefault: Bool

    public init(
        streamIndex: Int,
        codec: String,
        language: String,
        title: String,
        channels: Int?,
        isDefault: Bool
    ) {
        self.streamIndex = streamIndex
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.isDefault = isDefault
    }

    public var isEnglish: Bool { SubtitleLanguage.english.matches(language) }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let containerTitle: String?
    public let durationSeconds: Double?
    public let subtitleTracks: [SubtitleTrack]
    public let audioTracks: [AudioTrack]

    public init(
        fileURL: URL,
        containerTitle: String?,
        durationSeconds: Double?,
        subtitleTracks: [SubtitleTrack],
        audioTracks: [AudioTrack] = []
    ) {
        self.fileURL = fileURL
        self.containerTitle = containerTitle
        self.durationSeconds = durationSeconds
        self.subtitleTracks = subtitleTracks
        self.audioTracks = audioTracks
    }

    public var containsUnsupportedImageSubtitles: Bool {
        let imageCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]
        return subtitleTracks.contains { imageCodecs.contains($0.codec.lowercased()) }
    }
}

public struct MovieInfo: Codable, Equatable, Sendable {
    public var originalTitle: String
    public var chineseTitle: String
    public var year: Int?
    public var chineseTitleCandidates: [String]

    public init(originalTitle: String, chineseTitle: String = "", year: Int? = nil, chineseTitleCandidates: [String] = []) {
        self.originalTitle = originalTitle
        self.chineseTitle = chineseTitle
        self.year = year
        self.chineseTitleCandidates = chineseTitleCandidates
    }
}

public struct GlossaryEntry: Codable, Equatable, Sendable {
    public let source: String
    public let target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

public struct TranslationItem: Codable, Equatable, Sendable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

public struct TranslationResponse: Codable, Equatable, Sendable {
    public let items: [TranslationItem]
    public let glossaryUpdates: [GlossaryEntry]

    enum CodingKeys: String, CodingKey {
        case items
        case glossaryUpdates = "glossary_updates"
    }

    public init(items: [TranslationItem], glossaryUpdates: [GlossaryEntry] = []) {
        self.items = items
        self.glossaryUpdates = glossaryUpdates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([TranslationItem].self, forKey: .items)
        glossaryUpdates = try container.decodeIfPresent([GlossaryEntry].self, forKey: .glossaryUpdates) ?? []
    }
}

public struct TranslationChunk: Equatable, Sendable, Identifiable {
    public let index: Int
    public let core: [SubtitleCue]
    public let previousContext: [SubtitleCue]
    public let nextContext: [SubtitleCue]
    public var id: Int { index }

    public init(index: Int, core: [SubtitleCue], previousContext: [SubtitleCue], nextContext: [SubtitleCue]) {
        self.index = index
        self.core = core
        self.previousContext = previousContext
        self.nextContext = nextContext
    }
}

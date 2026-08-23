import Foundation
import MKVSubtitleCore

#if canImport(Translation)
import SwiftUI
import Translation

@available(macOS 15.0, *)
actor AppleTranslationProvider: TranslationProvider {
    typealias Handler = @Sendable (TranslationRequest) async throws -> String

    nonisolated let progressLabel = "Apple 本地翻译"

    private var handler: Handler?
    private var activationID: UUID?

    func activate(session: TranslationSession) async {
        let identifier = UUID()
        activationID = identifier
        handler = { request in
            try await Self.translate(request, using: session)
        }

        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(3_600))
            }
        } catch {
            // The SwiftUI translation task is expected to be cancelled when
            // the language pair or view changes.
        }

        if activationID == identifier {
            handler = nil
            activationID = nil
        }
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        try Task.checkCancellation()
        guard let handler else {
            throw AppError.localTranslationUnavailable(
                "系统翻译会话尚未准备好，请稍候一秒后重试。"
            )
        }
        return try await handler(request)
    }

    private static func translate(
        _ request: TranslationRequest,
        using session: TranslationSession
    ) async throws -> String {
        let protector = TranslationTextProtector()
        let protectedByID = Dictionary(uniqueKeysWithValues: request.chunk.core.map {
            ($0.id, protector.protect($0.text))
        })
        let requests = request.chunk.core.map {
            TranslationSession.Request(
                sourceText: protectedByID[$0.id]?.sourceText ?? $0.text,
                clientIdentifier: String($0.id)
            )
        }
        let responses = try await session.translations(from: requests)
        var items: [TranslationItem] = []
        items.reserveCapacity(responses.count)
        for response in responses {
            try Task.checkCancellation()
            guard let rawID = response.clientIdentifier,
                  let id = Int(rawID),
                  let protectedText = protectedByID[id] else {
                throw AppError.invalidTranslation("Apple 本地翻译返回了无法识别的字幕 ID。")
            }
            items.append(TranslationItem(
                id: id,
                text: try protectedText.restore(response.targetText)
            ))
        }
        let result = TranslationResponse(items: items.sorted { $0.id < $1.id })
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}

@available(macOS 15.0, *)
enum AppleTranslationRuntime {
    static let shared = AppleTranslationProvider()
}

@available(macOS 15.0, *)
struct AppleTranslationHost: View {
    let sourceLanguage: SubtitleLanguage
    let targetLanguage: SubtitleLanguage

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(
                source: Locale.Language(identifier: sourceLanguage.rawValue),
                target: Locale.Language(identifier: targetLanguage.rawValue)
            ) { session in
                await AppleTranslationRuntime.shared.activate(session: session)
            }
    }
}
#endif

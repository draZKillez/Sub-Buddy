import Foundation

/// Constrains shape and admissible IDs. Local validation still checks unique,
/// complete IDs, exact source binding, nonempty text and subtitle formatting.
public enum TranslationOutputSchema {
    public static func data(for cues: [SubtitleCue]) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["items", "glossary_updates"],
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["id", "source", "text"],
                        "properties": [
                            "id": ["type": "integer", "enum": cues.map(\.id)],
                            "source": ["type": "string"],
                            "text": ["type": "string"]
                        ]
                    ]
                ],
                "glossary_updates": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["source", "target"],
                        "properties": ["source": ["type": "string"], "target": ["type": "string"]]
                    ]
                ]
            ]
        ]
        guard !cues.isEmpty else { throw AppError.invalidTranslation("不能提交空字幕块。") }
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }
}

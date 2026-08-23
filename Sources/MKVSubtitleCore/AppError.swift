import Foundation

public enum AppError: LocalizedError, Equatable {
    case toolMissing(name: String, guidance: String)
    case processFailed(tool: String, code: Int32, message: String)
    case invalidMedia(String)
    case speechRecognition(String)
    case modelDownload(String)
    case unsupportedSubtitle(String)
    case parsingFailed(String)
    case codexNotLoggedIn
    case codexModelUnavailable(String)
    case codexQuotaUnavailable
    case codexServiceUnavailable
    case localTranslationUnavailable(String)
    case invalidTranslation(String)
    case manualSubtitleFormat(String)
    case outputExists(URL)
    case originalOverwriteForbidden
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .toolMissing(name, guidance): return "未检测到 \(name)。\(guidance)"
        case let .processFailed(tool, code, message): return "\(tool) 执行失败（退出码 \(code)）：\(message)"
        case let .invalidMedia(message): return "无法读取 MKV：\(message)"
        case let .speechRecognition(message): return "英文语音识别失败：\(message)"
        case let .modelDownload(message): return "Whisper 模型下载失败：\(message)"
        case let .unsupportedSubtitle(message): return message
        case let .parsingFailed(message): return "字幕解析失败：\(message)"
        case .codexNotLoggedIn: return "Codex CLI 尚未登录。请点击“连接 ChatGPT”，完成浏览器登录后重试。"
        case let .codexModelUnavailable(model): return "模型 \(model) 当前不可用。请确认该模型已对当前 ChatGPT 工作区开放；应用不会自动切换到其他模型。"
        case .codexQuotaUnavailable: return "当前 Codex 额度已用尽或暂不可用。请稍后重试或检查 ChatGPT 套餐额度。"
        case .codexServiceUnavailable: return "Codex 服务暂时不可用。请检查网络或服务状态后重试。"
        case let .localTranslationUnavailable(message): return "Apple 本地翻译不可用：\(message)"
        case let .invalidTranslation(message): return "模型返回格式无效：\(message)"
        case let .manualSubtitleFormat(message): return "手动字幕格式无效：\(message)"
        case let .outputExists(url): return "输出文件已存在：\(url.path)"
        case .originalOverwriteForbidden: return "为保护原文件，不能直接覆盖输入 MKV。"
        case .cancelled: return "任务已取消。已完成的字幕块进度已保存。"
        }
    }
}

import Foundation

public protocol MKVInspecting: Sendable {
    func inspect(_ url: URL) async throws -> MediaInfo
}

public final class MKVInspector: MKVInspecting, @unchecked Sendable {
    private let ffprobeURL: URL?
    private let executor: ProcessExecuting

    public init(ffprobeURL: URL?, executor: ProcessExecuting = ProcessExecutor()) {
        self.ffprobeURL = ffprobeURL
        self.executor = executor
    }

    public func inspect(_ url: URL) async throws -> MediaInfo {
        guard url.pathExtension.lowercased() == "mkv" else {
            throw AppError.invalidMedia("请选择 .mkv 文件。")
        }
        guard let ffprobeURL else {
            throw AppError.toolMissing(
                name: "ffprobe",
                guidance: "内嵌 ffprobe 未找到或不可执行。请重新安装本 App；也可运行 brew install ffmpeg 后重新检测。"
            )
        }
        let arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        let result = try await executor.run(executable: ffprobeURL, arguments: arguments, standardInput: nil)
        guard result.status == 0 else {
            throw AppError.processFailed(tool: "ffprobe", code: result.status, message: result.standardError)
        }
        guard let data = result.standardOutput.data(using: .utf8) else { throw AppError.invalidMedia("ffprobe 输出不是 UTF-8。") }
        do {
            let probe = try JSONDecoder().decode(ProbeResponse.self, from: data)
            let tracks = probe.streams.filter { $0.codecType == "subtitle" }.map { stream in
                let codec = stream.codecName ?? "unknown"
                let title = stream.tags?.title ?? ""
                return SubtitleTrack(
                    streamIndex: stream.index,
                    codec: codec,
                    language: stream.tags?.language ?? "und",
                    title: title,
                    isDefault: stream.disposition?.defaultValue == 1,
                    isForced: stream.disposition?.forced == 1,
                    isSDH: stream.disposition?.hearingImpaired == 1 || title.range(of: #"(?:\bSDH\b|\bhearing[ -]?impaired\b|\bCC\b)"#, options: [.regularExpression, .caseInsensitive]) != nil,
                    isText: Self.supportedTextCodecs.contains(codec.lowercased())
                )
            }
            let audioTracks = probe.streams.filter { $0.codecType == "audio" }.map { stream in
                AudioTrack(
                    streamIndex: stream.index,
                    codec: stream.codecName ?? "unknown",
                    language: stream.tags?.language ?? "und",
                    title: stream.tags?.title ?? "",
                    channels: stream.channels,
                    isDefault: stream.disposition?.defaultValue == 1
                )
            }
            return MediaInfo(
                fileURL: url,
                containerTitle: probe.format?.tags?.title,
                durationSeconds: probe.format?.duration.flatMap(Double.init),
                subtitleTracks: tracks,
                audioTracks: audioTracks
            )
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.invalidMedia("无法解析 ffprobe JSON：\(error.localizedDescription)")
        }
    }

    public static let supportedTextCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt"]
    public static let imageSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]

    private struct ProbeResponse: Decodable {
        let streams: [ProbeStream]
        let format: ProbeFormat?
    }
    private struct ProbeStream: Decodable {
        let index: Int
        let codecName: String?
        let codecType: String?
        let channels: Int?
        let tags: ProbeTags?
        let disposition: ProbeDisposition?
        enum CodingKeys: String, CodingKey {
            case index, channels, tags, disposition
            case codecName = "codec_name"
            case codecType = "codec_type"
        }
    }
    private struct ProbeFormat: Decodable { let duration: String?; let tags: ProbeTags? }
    private struct ProbeTags: Decodable { let language: String?; let title: String? }
    private struct ProbeDisposition: Decodable {
        let defaultValue: Int?
        let forced: Int?
        let hearingImpaired: Int?
        enum CodingKeys: String, CodingKey {
            case defaultValue = "default"
            case forced
            case hearingImpaired = "hearing_impaired"
        }
    }
}

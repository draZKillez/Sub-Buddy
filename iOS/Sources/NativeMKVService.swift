import Foundation
import MKVFFmpeg

final class NativeMKVService: @unchecked Sendable {
    private final class OperationHandle: @unchecked Sendable {
        let pointer: OpaquePointer
        private let lock = NSLock()
        private var cancellationRequested = false

        init?() {
            guard let pointer = mkvff_operation_state_create() else { return nil }
            self.pointer = pointer
        }

        deinit { mkvff_operation_state_free(pointer) }
        func cancel() {
            lock.lock()
            cancellationRequested = true
            lock.unlock()
            mkvff_operation_state_cancel(pointer)
        }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }
        var progress: Double { mkvff_operation_state_progress(pointer) }
    }

    var version: String {
        String(cString: mkvff_version())
    }

    func inspect(_ url: URL) async throws -> MediaInfo {
        guard let handle = OperationHandle() else {
            throw AppError.processFailed(tool: "内嵌 FFmpeg", code: -1, message: "无法创建任务状态。")
        }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var nativeInfo: UnsafeMutablePointer<MKVFFMediaInfo>?
                var errorMessage: UnsafeMutablePointer<CChar>?
                let status = url.path.withCString { path in
                    mkvff_inspect_cancellable(path, &nativeInfo, handle.pointer, &errorMessage)
                }
                defer {
                    if let nativeInfo { mkvff_media_info_free(nativeInfo) }
                    if let errorMessage { mkvff_string_free(errorMessage) }
                }
                if handle.isCancelled { throw CancellationError() }
                guard status == 0, let nativeInfo else {
                    let detail = errorMessage.map { String(cString: $0) } ?? "FFmpeg 无法读取该文件。"
                    throw AppError.invalidMedia(detail)
                }
                let value = nativeInfo.pointee
                let count = Int(value.subtitle_track_count)
                let tracks: [SubtitleTrack]
                if count > 0, let base = value.subtitle_tracks {
                    tracks = (0..<count).map { index in
                        let track = base.advanced(by: index).pointee
                        let codec = Self.string(from: track.codec)
                        let title = Self.string(from: track.title)
                        return SubtitleTrack(
                            streamIndex: Int(track.stream_index),
                            codec: codec,
                            language: Self.string(from: track.language),
                            title: title,
                            isDefault: track.is_default != 0,
                            isForced: track.is_forced != 0,
                            isSDH: track.is_hearing_impaired != 0 || SubtitleTrack.titleSuggestsSDH(title),
                            isText: track.is_text != 0
                        )
                    }
                } else {
                    tracks = []
                }
                let title = Self.string(from: value.container_title)
                return MediaInfo(
                    fileURL: url,
                    containerTitle: title.isEmpty ? nil : title,
                    durationSeconds: value.duration_seconds > 0 ? value.duration_seconds : nil,
                    subtitleTracks: tracks
                )
            }.value
        } onCancel: {
            handle.cancel()
        }
    }

    func extract(
        input: URL,
        track: SubtitleTrack,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let handle = OperationHandle() else {
            throw AppError.processFailed(tool: "内嵌 FFmpeg", code: -1, message: "无法创建任务状态。")
        }
        let monitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(handle.progress)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer {
            monitor.cancel()
            progress(handle.progress)
        }

        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var errorMessage: UnsafeMutablePointer<CChar>?
                let status = input.path.withCString { inputPath in
                    output.path.withCString { outputPath in
                        mkvff_extract_subtitle(
                            inputPath,
                            Int32(track.streamIndex),
                            outputPath,
                            handle.pointer,
                            &errorMessage
                        )
                    }
                }
                defer { if let errorMessage { mkvff_string_free(errorMessage) } }
                let detail = errorMessage.map { String(cString: $0) } ?? "字幕提取失败。"
                if handle.isCancelled || Task.isCancelled || detail.contains("任务已取消") {
                    throw CancellationError()
                }
                guard status == 0 else {
                    throw AppError.processFailed(tool: "内嵌 FFmpeg", code: status, message: detail)
                }
            }.value
        } onCancel: {
            handle.cancel()
        }
    }

    func decodeBitmapSubtitle(
        input: URL,
        track: SubtitleTrack,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard track.isVobSub else {
            throw AppError.unsupportedSubtitle("所选轨道不是 VobSub/DVD 图片字幕。")
        }
        guard let handle = OperationHandle() else {
            throw AppError.processFailed(tool: "内嵌 FFmpeg", code: -1, message: "无法创建任务状态。")
        }
        let monitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(handle.progress)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer {
            monitor.cancel()
            progress(handle.progress)
        }
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var errorMessage: UnsafeMutablePointer<CChar>?
                let status = input.path.withCString { inputPath in
                    output.path.withCString { outputPath in
                        mkvff_decode_bitmap_subtitle(
                            inputPath, Int32(track.streamIndex), outputPath,
                            handle.pointer, &errorMessage
                        )
                    }
                }
                defer { if let errorMessage { mkvff_string_free(errorMessage) } }
                let detail = errorMessage.map { String(cString: $0) } ?? "VobSub 解码失败。"
                if handle.isCancelled || Task.isCancelled || detail.contains("任务已取消") {
                    throw CancellationError()
                }
                guard status == 0 else {
                    throw AppError.processFailed(tool: "内嵌 FFmpeg VobSub 解码器", code: status, message: detail)
                }
            }.value
        } onCancel: {
            handle.cancel()
        }
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }
}

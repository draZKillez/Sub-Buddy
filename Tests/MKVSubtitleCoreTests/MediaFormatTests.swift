import Foundation
import XCTest
@testable import MKVSubtitleCore

final class MediaFormatTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }

    func testSupportedContainersAndLocalFileBoundary() {
        for ext in ["mkv", "MP4", "m4v", "MOV", "webm"] {
            XCTAssertTrue(MediaFileSupport.accepts(URL(fileURLWithPath: "/tmp/电影 & test.\(ext)")))
        }
        XCTAssertFalse(MediaFileSupport.accepts(URL(string: "https://example.com/video.mp4")!))
        XCTAssertFalse(MediaFileSupport.accepts(URL(fileURLWithPath: "/tmp/list.m3u8")))
        XCTAssertFalse(MediaFileSupport.accepts(URL(fileURLWithPath: "/tmp/sub.srt")))
    }

    func testFolderIncludesNewContainersWithoutHidingLegitimateSuffixedVideos() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["movie.mp4", "movie_zh.mkv", "movie_zh.mp4", "clip.MOV", "clip.m4v", "web.webm", "ignore.srt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let names = Set(try MKVFolderScanner().scan(folder).map(\.lastPathComponent))
        XCTAssertEqual(names, ["movie.mp4", "movie_zh.mp4", "clip.MOV", "clip.m4v", "web.webm"])
    }

    func testMovTextConversionBypassesMatroskaExtractor() async throws {
        let executor = MediaExecutor()
        let input = URL(fileURLWithPath: "/tmp/电影 $x.MP4")
        let track = SubtitleTrack(streamIndex: 2, codec: "mov_text", language: "eng", title: "English", isDefault: true, isForced: false, isSDH: false, isText: true)
        try await FFmpegService(ffmpegURL: URL(fileURLWithPath: "/tools/ffmpeg"), mkvextractURL: URL(fileURLWithPath: "/tools/mkvextract"), executor: executor).extractSubtitle(input: input, track: track, output: URL(fileURLWithPath: "/tmp/out.srt"))
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0.lastPathComponent, "ffmpeg")
        let args = calls[0].1
        XCTAssertEqual(args[args.firstIndex(of: "-c:s")! + 1], "subrip")
        XCTAssertTrue(args.contains(input.path))
        XCTAssertFalse(args.contains("-c:v"))
        XCTAssertEqual(try FFmpegService.subtitleFormat(for: "mov_text"), .srt)
        XCTAssertThrowsError(try FFmpegArguments().muxing(input: input, chineseSubtitle: URL(fileURLWithPath: "/tmp/s.srt"), output: URL(fileURLWithPath: "/tmp/result.mkv"), existingSubtitleCount: 1, overwrite: false))
    }

    func testBundledToolsPreserveMP4MOVWebMTimingAndM4VPaths() async throws {
        let tools = root.appendingPathComponent("Vendor/Tools/macos")
        let ffmpeg = tools.appendingPathComponent("ffmpeg")
        let ffprobe = tools.appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path), FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            if ProcessInfo.processInfo.environment["SUBBUDDY_BUNDLED_MEDIA_TESTS"] == "1" { XCTFail("Bundled tools must be built before release tests"); return }
            throw XCTSkip("Build bundled tools to run container integration tests")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let service = FFmpegService(ffmpegURL: ffmpeg, mkvextractURL: URL(fileURLWithPath: "/does-not-exist/mkvextract"))
        for (file, offset) in [("timed.mp4", Int64(0)), ("edited.mov", 2000), ("timed.webm", 0), ("特殊 空格 $file.M4V", 0)] {
            let input = temporary.appendingPathComponent(file)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(file.hasSuffix("M4V") ? "timed.mp4" : file), to: input)
            let info = try await MKVInspector(ffprobeURL: ffprobe).inspect(input)
            let track = try XCTUnwrap(info.subtitleTracks.first)
            XCTAssertTrue(track.isText, file)
            XCTAssertEqual(track.language, "eng")
            if file == "timed.mp4" { XCTAssertEqual(track.title, "English captions") }
            let format = try FFmpegService.subtitleFormat(for: track.codec)
            let output = temporary.appendingPathComponent(file + "." + FFmpegService.fileExtension(for: format))
            try await service.extractSubtitle(input: input, track: track, output: output, durationSeconds: info.durationSeconds)
            let document = try SubtitleParser().parse(contentsOf: output, format: format)
            XCTAssertEqual(document.cues.count, 2, file)
            XCTAssertEqual(document.cues.map(\.startMilliseconds), [1234 + offset, 3050 + offset], file)
            XCTAssertEqual(document.cues.map(\.endMilliseconds), [2789 + offset, 4100 + offset], file)
            XCTAssertTrue(document.cues[0].text.contains("friend"))
            XCTAssertTrue(document.cues[1].text.contains("\n"))
        }
        let empty = try await MKVInspector(ffprobeURL: ffprobe).inspect(fixtures.appendingPathComponent("no-subtitles.mp4"))
        XCTAssertTrue(empty.subtitleTracks.isEmpty)
    }
}

private actor MediaExecutor: ProcessExecuting {
    var calls: [(URL, [String])] = []
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        calls.append((executable, arguments))
        return .init(status: 0, standardOutput: "", standardError: "")
    }
}

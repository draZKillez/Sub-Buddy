import Foundation

public protocol FFmpegInstalling: Sendable {
    func install() async throws -> String
}

public final class HomebrewFFmpegInstaller: FFmpegInstalling, @unchecked Sendable {
    private let homebrewURL: URL?
    private let executor: ProcessExecuting

    public init(homebrewURL: URL?, executor: ProcessExecuting = ProcessExecutor()) {
        self.homebrewURL = homebrewURL
        self.executor = executor
    }

    public func install() async throws -> String {
        guard let homebrewURL else {
            throw AppError.toolMissing(
                name: "Homebrew",
                guidance: "请先从 brew.sh 安装 Homebrew，再返回应用安装 FFmpeg。"
            )
        }
        let result = try await executor.run(
            executable: homebrewURL,
            arguments: ["install", "ffmpeg"],
            standardInput: nil
        )
        let fullLog = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let log = String(fullLog.suffix(8_000))
        guard result.status == 0 else {
            throw AppError.processFailed(
                tool: "Homebrew",
                code: result.status,
                message: log.isEmpty ? "FFmpeg 安装失败，请检查 Homebrew 权限和网络连接。" : log
            )
        }
        return log.isEmpty ? "FFmpeg 安装完成。" : log
    }
}

public final class HomebrewMKVToolNixInstaller: FFmpegInstalling, @unchecked Sendable {
    private let homebrewURL: URL?
    private let executor: ProcessExecuting

    public init(homebrewURL: URL?, executor: ProcessExecuting = ProcessExecutor()) {
        self.homebrewURL = homebrewURL
        self.executor = executor
    }

    public func install() async throws -> String {
        guard let homebrewURL else {
            throw AppError.toolMissing(
                name: "Homebrew",
                guidance: "请先从 brew.sh 安装 Homebrew，再返回应用安装 MKVToolNix。"
            )
        }
        let result = try await executor.run(
            executable: homebrewURL,
            arguments: ["install", "mkvtoolnix"],
            standardInput: nil
        )
        let fullLog = [result.standardOutput, result.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let log = String(fullLog.suffix(8_000))
        guard result.status == 0 else {
            throw AppError.processFailed(
                tool: "Homebrew",
                code: result.status,
                message: log.isEmpty ? "MKVToolNix 安装失败，请检查 Homebrew 权限和网络连接。" : log
            )
        }
        return log.isEmpty ? "MKVToolNix 安装完成。" : log
    }
}

import XCTest
@testable import MKVSubtitleCore

final class FFmpegInstallerTests: XCTestCase {
    func testInstallerUsesHomebrewDirectlyWithArgumentArray() async throws {
        let executor = InstallerExecutor(result: ProcessResult(
            status: 0,
            standardOutput: "ffmpeg installed",
            standardError: ""
        ))
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let log = try await HomebrewFFmpegInstaller(homebrewURL: brew, executor: executor).install()
        XCTAssertEqual(log, "ffmpeg installed")
        XCTAssertEqual(executor.executable, brew)
        XCTAssertEqual(executor.arguments, ["install", "ffmpeg"])
        XCTAssertNil(executor.standardInput)
    }

    func testInstallerReportsMissingHomebrew() async {
        do {
            _ = try await HomebrewFFmpegInstaller(homebrewURL: nil).install()
            XCTFail("Expected Homebrew missing error")
        } catch let error as AppError {
            guard case let .toolMissing(name, guidance) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "Homebrew")
            XCTAssertTrue(guidance.contains("brew.sh"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstallerSurfacesHomebrewFailure() async {
        let executor = InstallerExecutor(result: ProcessResult(
            status: 1,
            standardOutput: "",
            standardError: "network unavailable"
        ))
        do {
            _ = try await HomebrewFFmpegInstaller(
                homebrewURL: URL(fileURLWithPath: "/usr/local/bin/brew"),
                executor: executor
            ).install()
            XCTFail("Expected installation failure")
        } catch let error as AppError {
            guard case let .processFailed(tool, code, message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(tool, "Homebrew")
            XCTAssertEqual(code, 1)
            XCTAssertTrue(message.contains("network unavailable"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMKVToolNixInstallerUsesOfficialHomebrewFormula() async throws {
        let executor = InstallerExecutor(result: ProcessResult(
            status: 0,
            standardOutput: "mkvtoolnix installed",
            standardError: ""
        ))
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let log = try await HomebrewMKVToolNixInstaller(homebrewURL: brew, executor: executor).install()
        XCTAssertEqual(log, "mkvtoolnix installed")
        XCTAssertEqual(executor.executable, brew)
        XCTAssertEqual(executor.arguments, ["install", "mkvtoolnix"])
    }
}

private final class InstallerExecutor: ProcessExecuting, @unchecked Sendable {
    let result: ProcessResult
    var executable: URL?
    var arguments: [String] = []
    var standardInput: Data?

    init(result: ProcessResult) {
        self.result = result
    }

    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        return result
    }
}

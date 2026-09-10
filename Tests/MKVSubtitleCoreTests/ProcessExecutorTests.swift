import XCTest
@testable import MKVSubtitleCore

final class ProcessExecutorTests: XCTestCase {
    func testExitedParentDoesNotWaitForDescendantToCloseOutputPipe() async throws {
        let start = Date()
        let script = "import os,time\nif os.fork()==0:\n time.sleep(4)\n os._exit(0)\nos.write(1,b'parent finished')\nos._exit(0)"
        let result = try await ProcessExecutor().run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], standardInput: nil
        )
        XCTAssertEqual(result.standardOutput, "parent finished")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "EOF drain must not wait for an inherited pipe")
    }

    func testByteStreamIncludesUTF8AndFinalEOFTailExactlyOnce() async throws {
        let bytes = CapturedProcessBytes()
        let payload = String(repeating: "你好🌍日本語\n", count: 5_000) + "最后一行"
        let result = try await ProcessExecutor().run(executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], standardInput: Data(payload.utf8), standardOutputDataHandler: { bytes.append($0) })
        XCTAssertEqual(bytes.snapshot(), Data(payload.utf8))
        XCTAssertEqual(result.standardOutput, payload)
    }
    func testRunsWithoutShellAndCapturesStdoutAndStderr() async throws {
        let result = try await ProcessExecutor().run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; print('out'); print('err', file=sys.stderr)"],
            standardInput: nil
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines), "err")
    }

    func testPassesStandardInputWithoutCommandLineConcatenation() async throws {
        let result = try await ProcessExecutor().run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; print(sys.stdin.read())"],
            standardInput: Data("中文 字幕 $() ; ' \"".utf8)
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "中文 字幕 $() ; ' \"")
    }

    func testCancellationTerminatesRunningProcessPromptly() async {
        let start = ContinuousClock.now
        let task = Task {
            try await ProcessExecutor().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                standardInput: nil
            )
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled process unexpectedly completed")
        } catch is CancellationError {
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancellationForceKillsProcessThatIgnoresSIGTERM() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessExecutorReady-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = """
        import signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open(sys.argv[1], 'w').close()
        time.sleep(10)
        """
        let task = Task {
            try await ProcessExecutor().run(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, marker.path],
                standardInput: nil
            )
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Helper process did not become ready")
        let cancellationStarted = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled process unexpectedly completed")
        } catch is CancellationError {
            let duration = cancellationStarted.duration(to: .now)
            XCTAssertGreaterThanOrEqual(duration, .seconds(1.5), "SIGTERM should have been ignored")
            XCTAssertLessThan(duration, .seconds(4), "SIGKILL fallback did not run promptly")
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}

private final class CapturedProcessBytes: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk) }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

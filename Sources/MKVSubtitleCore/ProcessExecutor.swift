import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProcessResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ProcessExecuting: Sendable {
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult
}

public protocol StreamingProcessExecuting: ProcessExecuting {
    func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        standardOutputHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult
}

public final class ProcessExecutor: StreamingProcessExecuting, @unchecked Sendable {
    public init() {}

    public func run(executable: URL, arguments: [String], standardInput: Data? = nil) async throws -> ProcessResult {
        try await runInternal(executable: executable, arguments: arguments, standardInput: standardInput, standardOutputHandler: nil)
    }

    public func run(
        executable: URL,
        arguments: [String],
        standardInput: Data? = nil,
        standardOutputHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try await runInternal(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            standardOutputHandler: standardOutputHandler
        )
    }

    private func runInternal(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        standardOutputHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        // FFmpeg and Codex can be verbose. Keeping an unlimited transcript here
        // makes a long-running job grow the App indefinitely, while callers only
        // need the final JSONL/error tail to diagnose a failure.
        let outputBuffer = LockedDataBuffer(maximumBytes: 16 * 1_024 * 1_024)
        let errorBuffer = LockedDataBuffer(maximumBytes: 8 * 1_024 * 1_024)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
            standardOutputHandler?(String(decoding: data, as: UTF8.self))
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errorBuffer.append(data)
        }

        let cancellationState = ProcessCancellationState(process: process)

        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                guard !cancellationState.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                    cancellationState.terminateIfCancelled()
                    if let standardInput {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                    }
                    try? inputPipe.fileHandleForWriting.close()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if let remainder = try? outputPipe.fileHandleForReading.readToEnd() {
                outputBuffer.append(remainder)
            }
            if let remainder = try? errorPipe.fileHandleForReading.readToEnd() {
                errorBuffer.append(remainder)
            }
            try Task.checkCancellation()
            let stdout = String(decoding: outputBuffer.snapshot(), as: UTF8.self)
            let stderr = String(decoding: errorBuffer.snapshot(), as: UTF8.self)
            return ProcessResult(status: status, standardOutput: stdout, standardError: stderr)
        }, onCancel: {
            cancellationState.cancel()
        })
    }
}

private final class ProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var forceKillScheduled = false

    init(process: Process) {
        self.process = process
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let shouldTerminate = process.isRunning
        let shouldScheduleKill = shouldTerminate && !forceKillScheduled
        if shouldScheduleKill { forceKillScheduled = true }
        lock.unlock()
        if shouldTerminate {
            process.terminate()
            if shouldScheduleKill { scheduleForceKill() }
        }
    }

    func terminateIfCancelled() {
        lock.lock()
        let shouldTerminate = cancelled && process.isRunning
        let shouldScheduleKill = shouldTerminate && !forceKillScheduled
        if shouldScheduleKill { forceKillScheduled = true }
        lock.unlock()
        if shouldTerminate {
            process.terminate()
            if shouldScheduleKill { scheduleForceKill() }
        }
    }

    private func scheduleForceKill() {
        #if canImport(Darwin)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let pid = self.process.isRunning ? self.process.processIdentifier : 0
            self.lock.unlock()
            if pid > 0 { Darwin.kill(pid, SIGKILL) }
        }
        #endif
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var discardedByteCount = 0

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ value: Data) {
        lock.lock()
        data.append(value)
        if data.count > maximumBytes {
            let overflow = data.count - maximumBytes
            data.removeFirst(overflow)
            discardedByteCount += overflow
        }
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard discardedByteCount > 0 else { return data }
        let marker = "[前方输出因过长已省略 \(discardedByteCount) 字节]\n"
        return Data(marker.utf8) + data
    }
}

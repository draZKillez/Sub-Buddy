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

/// JSONL must be framed as bytes before UTF-8 decoding: a pipe read can split
/// a Chinese character (or any multi-byte code point) in the middle.
public protocol DataStreamingProcessExecuting: ProcessExecuting {
    func run(executable: URL, arguments: [String], standardInput: Data?,
             standardOutputDataHandler: @escaping @Sendable (Data) -> Void) async throws -> ProcessResult
}

public final class ProcessExecutor: StreamingProcessExecuting, DataStreamingProcessExecuting, @unchecked Sendable {
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

    public func run(executable: URL, arguments: [String], standardInput: Data?,
                    standardOutputDataHandler: @escaping @Sendable (Data) -> Void) async throws -> ProcessResult {
        try await runInternal(executable: executable, arguments: arguments, standardInput: standardInput,
                              standardOutputHandler: nil, standardOutputDataHandler: standardOutputDataHandler)
    }

    private func runInternal(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        standardOutputHandler: (@Sendable (String) -> Void)?,
        standardOutputDataHandler: (@Sendable (Data) -> Void)? = nil
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
        let outputReader = SerializedPipeReader { data in
            outputBuffer.append(data)
            standardOutputHandler?(String(decoding: data, as: UTF8.self))
            standardOutputDataHandler?(data)
        }
        let errorReader = SerializedPipeReader { errorBuffer.append($0) }
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputReader.read(handle)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errorReader.read(handle)
        }
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
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
            outputReader.finish(outputPipe.fileHandleForReading)
            errorReader.finish(errorPipe.fileHandleForReading)
            try Task.checkCancellation()
            let stdout = String(decoding: outputBuffer.snapshot(), as: UTF8.self)
            let stderr = String(decoding: errorBuffer.snapshot(), as: UTF8.self)
            return ProcessResult(status: status, standardOutput: stdout, standardError: stderr)
        }, onCancel: {
            cancellationState.cancel()
        })
    }
}

/// Serializes an in-flight readability callback with the final EOF drain.
/// In particular, the final bytes must also reach streaming consumers.
private final class SerializedPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let receive: @Sendable (Data) -> Void
    init(receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
    func read(_ handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let data = handle.availableData
        if !data.isEmpty { receive(data) }
    }
    func finish(_ handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        #if canImport(Darwin)
        // A descendant may inherit stdout after the launched parent exits.
        // readToEnd() would wait for that descendant forever, defeating our
        // cancellation/timeout. Drain only bytes already available, bounded.
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
        defer { _ = fcntl(descriptor, F_SETFL, flags) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var drained = 0
        while drained < 32 * 1_024 * 1_024 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                drained += count
                receive(Data(buffer.prefix(count)))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        #else
        if let data = try? handle.readToEnd(), !data.isEmpty { receive(data) }
        #endif
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
    private let trimmingThreshold: Int
    private var data = Data()
    private var discardedByteCount = 0

    init(maximumBytes: Int) {
        self.maximumBytes = max(1, maximumBytes)
        // Do not shift a multi-megabyte Data value for every small pipe read
        // after the limit is reached. Keep a bounded amount of slack and trim
        // in larger batches instead.
        let slack = min(1 * 1_024 * 1_024, max(64 * 1_024, maximumBytes / 8))
        self.trimmingThreshold = max(1, maximumBytes) + slack
    }

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.lock()
        if value.count >= maximumBytes {
            discardedByteCount += data.count + value.count - maximumBytes
            data = Data(value.suffix(maximumBytes))
        } else {
            data.append(value)
        }
        if data.count > trimmingThreshold {
            let overflow = data.count - maximumBytes
            data.removeFirst(overflow)
            discardedByteCount += overflow
        }
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let inMemoryOverflow = max(0, data.count - maximumBytes)
        let totalDiscarded = discardedByteCount + inMemoryOverflow
        let tail = inMemoryOverflow > 0 ? Data(data.suffix(maximumBytes)) : data
        guard totalDiscarded > 0 else { return tail }
        let marker = "[前方输出因过长已省略 \(totalDiscarded) 字节]\n"
        return Data(marker.utf8) + tail
    }
}

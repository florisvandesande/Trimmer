import Foundation

public struct CommandFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Runs off the main thread. File-backed output avoids pipe deadlocks and unbounded RAM use.
public enum Command {
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String],
                           environment: [String: String] = [:],
                           outputFile: URL? = nil,
                           onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Data {
        let job = RunningCommand()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try job.run(executable, arguments, environment,
                                                                   outputFile, onProgress))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { job.cancel() })
    }
}

private final class RunningCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(_ executable: URL, _ arguments: [String], _ environment: [String: String],
             _ outputFile: URL?, _ progress: (@Sendable (String) -> Void)?) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = outputFile ?? directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: stdout)
        let errHandle = try FileHandle(forWritingTo: stderr)
        defer { try? outHandle.close(); try? errHandle.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = outHandle
        child.standardError = errHandle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let reader = try FileHandle(forReadingFrom: stdout)
        defer { try? reader.close() }
        while child.isRunning {
            if let progress, let data = try reader.readToEnd(), !data.isEmpty {
                progress(String(decoding: data, as: UTF8.self))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        child.waitUntilExit()
        if let progress, let data = try reader.readToEnd(), !data.isEmpty {
            progress(String(decoding: data, as: UTF8.self))
        }
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if child.terminationStatus != 0 {
            let details = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
            throw CommandFailure(details.isEmpty ? "De opdracht is mislukt (\(child.terminationStatus))." : String(details.suffix(6000)))
        }
        return outputFile == nil ? try Data(contentsOf: stdout) : Data()
    }
}

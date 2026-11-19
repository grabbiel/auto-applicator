import Foundation

/// How a command ended and what it printed.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var output: String
    public var errors: String

    public init(status: Int32, output: String, errors: String) {
        self.status = status
        self.output = output
        self.errors = errors
    }

    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// An app opened from the Finder gets a bare PATH; the AWS CLI lives in one of these.
    public static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The first of `names` found on `path`.
    public static func find(_ name: String) -> URL? {
        path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs a program to its end. `onLine` gets each line as it's printed (both streams), for a log to follow.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], directory: URL? = nil,
                           onLine: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path
                env.merge(environment) { _, new in new }
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let output = Stream(), errors = Stream()
                let reading = DispatchGroup()
                for (pipe, stream) in [(out, output), (err, errors)] {
                    reading.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        stream.read(pipe.fileHandleForReading, onLine: onLine)
                        reading.leave()
                    }
                }
                process.waitUntilExit()
                reading.wait()
                continuation.resume(returning: CommandResult(status: process.terminationStatus, output: output.text, errors: errors.text))
            }
        }
    }

    /// One of a command's two streams, read to its end on its own thread.
    private final class Stream: @unchecked Sendable {
        private var data = Data()
        var text: String { String(decoding: data, as: UTF8.self) }

        func read(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)?) {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                guard let onLine else { continue }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
        }
    }
}

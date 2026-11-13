import Foundation
import Network

public enum IMAPError: LocalizedError, Sendable {
    case connect(String)
    case login
    case command(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connect(let m): "Couldn't reach the mail server (\(m))."
        case .login: "The mail server didn't accept that email and app password."
        case .command(let m): "The mail server answered: \(m)"
        case .timeout: "The mail server took too long to answer."
        }
    }
}

/// A minimal IMAP client over TLS (Network.framework): enough to log in, search and fetch messages.
final class IMAPClient: @unchecked Sendable {
    struct Response {
        var untagged: [(line: String, literal: Data?)] = []
        var status: String = ""
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "imap")
    private var buffer = Data()
    private var tag = 0
    private let timeout: TimeInterval

    init(host: String, port: Int, timeout: TimeInterval = 20) {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)), using: params)
        self.timeout = timeout
    }

    deinit { connection.cancel() }

    func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e), .waiting(let e): once.run { cont.resume(throwing: IMAPError.connect(e.localizedDescription)) }
                case .cancelled: once.run { cont.resume(throwing: IMAPError.connect("cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                once.run { cont.resume(throwing: IMAPError.timeout); connection.cancel() }
            }
        }
        _ = try await readLine()  // server greeting
    }

    func close() {
        Task { [self] in _ = try? await command("LOGOUT") }
        queue.asyncAfter(deadline: .now() + 1) { [connection] in connection.cancel() }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func login(user: String, password: String) async throws {
        do {
            _ = try await command("LOGIN \(Self.quote(user)) \(Self.quote(password))")
        } catch IMAPError.command {
            throw IMAPError.login
        }
    }

    @discardableResult
    func command(_ text: String) async throws -> Response {
        tag += 1
        let t = String(format: "A%03d", tag)
        try await send("\(t) \(text)\r\n")
        var response = Response()
        while true {
            let line = try await readLine()
            var literal: Data?
            var full = line
            // A line ending in {n} is followed by n raw bytes, then the rest of the line.
            if let g = Regex(#"\{(\d+)\}$"#, []).firstGroups(line), let n = Int(g[1] ?? "") {
                literal = try await readBytes(n)
                full += " " + (try await readLine())
            }
            if full.hasPrefix(t + " ") {
                let status = String(full.dropFirst(t.count + 1))
                response.status = status
                if !status.hasPrefix("OK") { throw IMAPError.command(status) }
                return response
            }
            response.untagged.append((full, literal))
        }
    }

    // MARK: high level

    func select(_ mailbox: String = "INBOX") async throws { try await command("SELECT \(mailbox)") }

    /// UIDs of messages received on or after the given day, newest first.
    func searchSince(_ date: Date) async throws -> [Int] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy"
        let r = try await command("UID SEARCH SINCE \(f.string(from: date.addingTimeInterval(-86400)))")
        return Self.searchResults(r).reversed()
    }

    func searchAll() async throws -> [Int] {
        Self.searchResults(try await command("UID SEARCH ALL"))
    }

    static func searchResults(_ r: Response) -> [Int] {
        r.untagged.filter { $0.line.hasPrefix("* SEARCH") }.flatMap { $0.line.split(separator: " ").dropFirst(2).compactMap { Int($0) } }
    }

    func fetch(uid: Int) async throws -> Data? {
        let r = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        return r.untagged.first { $0.literal != nil }?.literal
    }

    func markSeen(uid: Int) async throws { try await command("UID STORE \(uid) +FLAGS (\\Seen)") }

    func unseenCount() async throws -> Int {
        Self.searchResults(try await command("UID SEARCH UNSEEN")).count
    }

    // MARK: transport

    private func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: IMAPError.connect(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    private func fill() async throws {
        let chunk: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                once.run {
                    if let error { cont.resume(throwing: IMAPError.connect(error.localizedDescription)) }
                    else if let data, !data.isEmpty { cont.resume(returning: data) }
                    else if complete { cont.resume(throwing: IMAPError.connect("connection closed")) }
                    else { cont.resume(returning: Data()) }
                }
            }
            // The connection is useless after a timeout: cancelling it also ends the pending receive.
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                once.run { cont.resume(throwing: IMAPError.timeout); connection.cancel() }
            }
        }
        buffer.append(chunk)
    }

    private func readLine() async throws -> String {
        while true {
            if let r = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = Data(buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }
}

/// Runs a block of work at most once (continuations must be resumed exactly once).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

struct DeadlineExceeded: Error {}

/// Runs `body`, throwing `IMAPError.timeout` (or the given error) if it takes longer than `seconds`.
/// `body` must react to cancellation (the group waits for it to finish).
func withDeadline<T: Sendable>(_ seconds: TimeInterval, error: Error = IMAPError.timeout,
                               _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw error
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

import Foundation
import SQLite3

public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case applied = "APPLIED"
    case practiceComplete = "DRY_RUN_COMPLETE"
    case skippedBlacklist = "SKIPPED_BLACKLIST"
    case skippedTitleFilter = "SKIPPED_TITLE_FILTER"
    case skippedAlreadyApplied = "SKIPPED_ALREADY_APPLIED"
    case needsAnswer = "SKIPPED_NEEDS_ANSWER"
    case failedOTPTimeout = "FAILED_OTP_TIMEOUT"
    case failedForm = "FAILED_FORM_ERROR"

    /// Never retried: the outcome is final.
    public var isFinal: Bool { [.applied, .skippedBlacklist, .skippedTitleFilter, .skippedAlreadyApplied].contains(self) }
    public var isFailure: Bool { self == .failedForm || self == .failedOTPTimeout }

    public var label: String {
        switch self {
        case .applied: "Sent"
        case .practiceComplete: "Practice: ready to send"
        case .skippedBlacklist: "Skipped: company on your list"
        case .skippedTitleFilter: "Skipped: title filter"
        case .skippedAlreadyApplied: "Already applied"
        case .needsAnswer: "Waiting for your answer"
        case .failedOTPTimeout: "Didn't finish: no email code"
        case .failedForm: "Didn't finish"
        }
    }

    public var shortLabel: String {
        switch self {
        case .applied: "Sent"
        case .practiceComplete: "Practice"
        case .skippedBlacklist, .skippedTitleFilter: "Filtered"
        case .skippedAlreadyApplied: "Applied before"
        case .needsAnswer: "Needs you"
        case .failedOTPTimeout, .failedForm: "Didn't finish"
        }
    }
}

public enum ATSType: String, Codable, CaseIterable, Sendable {
    case easyApply = "LINKEDIN_EASY_APPLY"
    case greenhouse = "GREENHOUSE"
    case lever = "LEVER"
    case ashby = "ASHBY"
    case workday = "WORKDAY"
    case generic = "GENERIC_EXTERNAL"

    public var label: String {
        switch self {
        case .easyApply: "LinkedIn Easy Apply"
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .workday: "Workday"
        case .generic: "Company site"
        }
    }
}

public struct JobRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var company: String
    public var location: String
    public var ats: ATSType?
    public var url: String
    public var externalURL: String
    public var status: JobStatus?
    public var rawStatus: String
    public var notes: String
    public var attempts: Int
    public var updatedAt: Date?
    public var evidence: String
}

public struct CachedAnswer: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var question: String
    public var fieldType: String
    public var options: [String]
    public var answer: String
    /// "user" (you answered), "edited" (you changed it), "profile", or "llm:high" / "llm:medium" (the AI decided).
    public var source: String
    public var updatedAt: Date?

    public var learnedFromUser: Bool { source == "user" || source == "edited" }
}

public struct PendingQuestion: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public var hash: String
    public var question: String
    public var fieldType: String
    public var options: [String]
    public var jobIDs: [String]
    public var companies: [String]
    public var lastSeen: Date?
}

public struct Fact: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var text: String
    public var createdAt: Date?
}

public struct RunRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var startedAt: Date?
    public var finishedAt: Date?
    public var practice: Bool
    public var sent: Int
    public var prepared: Int
    public var needsAnswer: Int
    public var failed: Int
    public var note: String
}

/// SQLite state: jobs and their outcomes, learned answers (qa_cache), questions waiting for the user, facts the user
/// taught the app, and run history. The first three tables keep version 0.3's schema, so an upgrade keeps them.
public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        if path != ":memory:" {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError(message: "Couldn't open the database: \(message)")
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY, title TEXT, company TEXT, location TEXT, ats_type TEXT, url TEXT, external_url TEXT,
            status TEXT, notes TEXT, attempts INTEGER NOT NULL DEFAULT 0, updated_at DATETIME);
        CREATE TABLE IF NOT EXISTS qa_cache (
            question_hash TEXT PRIMARY KEY, question_text TEXT, field_type TEXT, options_json TEXT, answer TEXT, source TEXT,
            updated_at DATETIME);
        CREATE TABLE IF NOT EXISTS pending_questions (
            question_hash TEXT PRIMARY KEY, question_text TEXT, field_type TEXT, options_json TEXT, job_ids TEXT, companies TEXT,
            first_seen DATETIME, last_seen DATETIME);
        CREATE TABLE IF NOT EXISTS facts (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, created_at DATETIME);
        CREATE TABLE IF NOT EXISTS runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT, started_at DATETIME, finished_at DATETIME, practice INTEGER, sent INTEGER DEFAULT 0,
            prepared INTEGER DEFAULT 0, needs_answer INTEGER DEFAULT 0, failed INTEGER DEFAULT 0, note TEXT DEFAULT '');
        """)
        if !columnExists("jobs", "evidence") { try exec("ALTER TABLE jobs ADD COLUMN evidence TEXT") }
    }

    public convenience init(paths: AppPaths) throws {
        try self.init(path: paths.database.path)
    }

    deinit { sqlite3_close(db) }

    // MARK: - plumbing

    public struct DatabaseError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "SQL error"
            sqlite3_free(err)
            throw DatabaseError(message: message)
        }
    }

    private func columnExists(_ table: String, _ column: String) -> Bool {
        query("PRAGMA table_info(\(table))") { $0.string(1) }.contains(column)
    }

    enum Value {
        case text(String?)
        case int(Int64)
    }

    struct Row {
        let stmt: OpaquePointer
        func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func optionalString(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : string(i)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    }

    private func prepare(_ sql: String, _ args: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.error("SQL prepare failed: \(String(cString: sqlite3_errmsg(db))) – \(sql.prefix(80))")
            return nil
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (n, arg) in args.enumerated() {
            let idx = Int32(n + 1)
            switch arg {
            case .text(let s?): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .text(nil): sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            }
        }
        return stmt
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            Log.error("SQL failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    func query<T>(_ sql: String, _ args: [Value] = [], _ map: (Row) -> T) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(Row(stmt: stmt))) }
        return out
    }

    private var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    // Version 0.3 wrote Python's isoformat ("2026-01-02T03:04:05+00:00"); keep the same, it sorts as text.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func now() -> String { isoFormatter.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00") }

    static func date(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = isoFormatter.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func json(_ list: [String]) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }

    static func list(_ json: String) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String] ?? []
    }

    // MARK: - jobs

    private func jobRecord(_ r: Row) -> JobRecord {
        let raw = r.string(7)
        return JobRecord(id: r.string(0), title: r.string(1), company: r.string(2), location: r.string(3),
                         ats: ATSType(rawValue: r.string(4)), url: r.string(5), externalURL: r.string(6), status: JobStatus(rawValue: raw),
                         rawStatus: raw, notes: r.string(8), attempts: r.int(9), updatedAt: Database.date(r.string(10)), evidence: r.string(11))
    }

    private let jobColumns = "job_id, title, company, location, ats_type, url, external_url, status, notes, attempts, updated_at, evidence"

    public func job(_ id: String) -> JobRecord? {
        query("SELECT \(jobColumns) FROM jobs WHERE job_id = ?", [.text(id)], jobRecord).first
    }

    public func upsertJob(_ id: String, status: JobStatus, title: String? = nil, company: String? = nil, location: String? = nil,
                          ats: ATSType? = nil, url: String? = nil, externalURL: String? = nil, notes: String? = nil,
                          evidence: String? = nil, countAttempt: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let old = job(id)
        run("""
            INSERT INTO jobs (job_id, title, company, location, ats_type, url, external_url, status, notes, attempts, updated_at, evidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET title=excluded.title, company=excluded.company, location=excluded.location,
              ats_type=excluded.ats_type, url=excluded.url, external_url=excluded.external_url, status=excluded.status,
              notes=excluded.notes, attempts=excluded.attempts, updated_at=excluded.updated_at, evidence=excluded.evidence
            """, [
                .text(id), .text(title ?? old?.title), .text(company ?? old?.company), .text(location ?? old?.location),
                .text(ats?.rawValue ?? old?.ats?.rawValue), .text(url ?? old?.url), .text(externalURL ?? old?.externalURL),
                .text(status.rawValue), .text(notes ?? old?.notes), .int(Int64((old?.attempts ?? 0) + (countAttempt ? 1 : 0))),
                .text(Database.now()), .text(evidence ?? old?.evidence),
            ])
    }

    /// Why an already-seen job shouldn't be processed again (nil: process it).
    public func skipReason(_ id: String, practice: Bool, maxAttempts: Int) -> String? {
        guard let job = job(id) else { return nil }
        guard let status = job.status else { return nil }
        if status.isFinal { return status.rawValue }
        if status == .practiceComplete { return practice ? status.rawValue : nil }
        if status == .needsAnswer { return jobHasPending(id) ? status.rawValue : nil }
        if status.isFailure && job.attempts >= maxAttempts { return "\(status.rawValue) (gave up after \(job.attempts) attempts)" }
        return nil
    }

    public func recentJobs(limit: Int = 200) -> [JobRecord] {
        query("SELECT \(jobColumns) FROM jobs ORDER BY updated_at DESC LIMIT ?", [.int(Int64(limit))], jobRecord)
    }

    public func statusCounts(since: Date? = nil) -> [JobStatus: Int] {
        let rows: [(String, Int)]
        if let since {
            let s = Database.isoFormatter.string(from: since).replacingOccurrences(of: "Z", with: "+00:00")
            rows = query("SELECT status, COUNT(*) FROM jobs WHERE updated_at >= ? GROUP BY status", [.text(s)]) { ($0.string(0), $0.int(1)) }
        } else {
            rows = query("SELECT status, COUNT(*) FROM jobs GROUP BY status") { ($0.string(0), $0.int(1)) }
        }
        var out: [JobStatus: Int] = [:]
        for (raw, n) in rows { if let s = JobStatus(rawValue: raw) { out[s, default: 0] += n } }
        return out
    }

    public func deleteJob(_ id: String) { run("DELETE FROM jobs WHERE job_id = ?", [.text(id)]) }

    // MARK: - learned answers (qa_cache)

    private func cachedAnswer(_ r: Row) -> CachedAnswer {
        CachedAnswer(hash: r.string(0), question: r.string(1), fieldType: r.string(2), options: Database.list(r.string(3)),
                     answer: r.string(4), source: r.string(5), updatedAt: Database.date(r.string(6)))
    }

    public func cacheGet(_ hash: String) -> String? {
        query("SELECT answer FROM qa_cache WHERE question_hash = ?", [.text(hash)]) { $0.optionalString(0) }.first ?? nil
    }

    public func cacheSource(_ hash: String) -> String? {
        query("SELECT source FROM qa_cache WHERE question_hash = ?", [.text(hash)]) { $0.string(0) }.first
    }

    public func cachePut(_ hash: String, question: String, fieldType: String, options: [String], answer: String, source: String) {
        run("""
            INSERT INTO qa_cache (question_hash, question_text, field_type, options_json, answer, source, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(question_hash) DO UPDATE SET answer=excluded.answer, source=excluded.source, updated_at=excluded.updated_at
            """, [.text(hash), .text(question), .text(fieldType), .text(Database.json(options)), .text(answer), .text(source), .text(Database.now())])
    }

    public func cacheDelete(_ hash: String) { run("DELETE FROM qa_cache WHERE question_hash = ?", [.text(hash)]) }

    public func cacheEntries() -> [CachedAnswer] {
        query("SELECT question_hash, question_text, field_type, options_json, answer, source, updated_at FROM qa_cache ORDER BY updated_at DESC",
              [], cachedAnswer)
    }

    // MARK: - questions waiting for the user

    public func addPending(_ hash: String, question: String, fieldType: String, options: [String], jobID: String, company: String) {
        lock.lock()
        defer { lock.unlock() }
        let ts = Database.now()
        let existing = query("SELECT job_ids, companies FROM pending_questions WHERE question_hash = ?", [.text(hash)]) {
            (Database.list($0.string(0)), Database.list($0.string(1)))
        }.first
        if let (jobs, companies) = existing {
            let j = Array(Set(jobs + [jobID])).sorted()
            let c = Array(Set(companies + (company.isEmpty ? [] : [company]))).sorted()
            run("UPDATE pending_questions SET job_ids=?, companies=?, last_seen=? WHERE question_hash=?",
                [.text(Database.json(j)), .text(Database.json(c)), .text(ts), .text(hash)])
        } else {
            run("""
                INSERT INTO pending_questions (question_hash, question_text, field_type, options_json, job_ids, companies, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(hash), .text(question), .text(fieldType), .text(Database.json(options)), .text(Database.json([jobID])),
                      .text(Database.json(company.isEmpty ? [] : [company])), .text(ts), .text(ts)])
        }
    }

    public func listPending() -> [PendingQuestion] {
        query("SELECT question_hash, question_text, field_type, options_json, job_ids, companies, last_seen FROM pending_questions ORDER BY last_seen DESC") {
            PendingQuestion(hash: $0.string(0), question: $0.string(1), fieldType: $0.string(2), options: Database.list($0.string(3)),
                            jobIDs: Database.list($0.string(4)), companies: Database.list($0.string(5)), lastSeen: Database.date($0.string(6)))
        }
    }

    public var pendingCount: Int { query("SELECT COUNT(*) FROM pending_questions") { $0.int(0) }.first ?? 0 }

    /// Saves the user's answer for every future application and removes the question from the inbox.
    public func resolvePending(_ hash: String, answer: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let q = listPending().first(where: { $0.hash == hash }) else { return }
        cachePut(hash, question: q.question, fieldType: q.fieldType, options: q.options, answer: answer, source: "user")
        run("DELETE FROM pending_questions WHERE question_hash = ?", [.text(hash)])
    }

    public func dismissPending(_ hash: String) { run("DELETE FROM pending_questions WHERE question_hash = ?", [.text(hash)]) }

    public func jobHasPending(_ jobID: String) -> Bool {
        query("SELECT job_ids FROM pending_questions") { Database.list($0.string(0)) }.contains { $0.contains(jobID) }
    }

    // MARK: - facts the user taught the app

    public func facts() -> [Fact] {
        query("SELECT id, text, created_at FROM facts ORDER BY id DESC") { Fact(id: $0.int64(0), text: $0.string(1), createdAt: Database.date($0.string(2))) }
    }

    @discardableResult
    public func addFact(_ text: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        run("INSERT INTO facts (text, created_at) VALUES (?, ?)", [.text(text.trimmed), .text(Database.now())])
        return lastInsertID
    }

    public func updateFact(_ id: Int64, text: String) { run("UPDATE facts SET text = ? WHERE id = ?", [.text(text.trimmed), .int(id)]) }
    public func deleteFact(_ id: Int64) { run("DELETE FROM facts WHERE id = ?", [.int(id)]) }

    // MARK: - runs

    public func startRun(practice: Bool) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        run("INSERT INTO runs (started_at, practice) VALUES (?, ?)", [.text(Database.now()), .int(practice ? 1 : 0)])
        return lastInsertID
    }

    public func finishRun(_ id: Int64, sent: Int, prepared: Int, needsAnswer: Int, failed: Int, note: String) {
        run("UPDATE runs SET finished_at=?, sent=?, prepared=?, needs_answer=?, failed=?, note=? WHERE id=?",
            [.text(Database.now()), .int(Int64(sent)), .int(Int64(prepared)), .int(Int64(needsAnswer)), .int(Int64(failed)), .text(note), .int(id)])
    }

    public func recentRuns(limit: Int = 20) -> [RunRecord] {
        query("SELECT id, started_at, finished_at, practice, sent, prepared, needs_answer, failed, note FROM runs ORDER BY id DESC LIMIT ?",
              [.int(Int64(limit))]) {
            RunRecord(id: $0.int64(0), startedAt: Database.date($0.string(1)), finishedAt: Database.date($0.string(2)), practice: $0.int(3) == 1,
                      sent: $0.int(4), prepared: $0.int(5), needsAnswer: $0.int(6), failed: $0.int(7), note: $0.string(8))
        }
    }

    /// Applications sent (or prepared in practice) per day for the last `days` days, oldest first.
    public func dailyActivity(days: Int) -> [(day: Date, sent: Int, prepared: Int)] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        var buckets: [Date: (Int, Int)] = [:]
        for job in recentJobs(limit: 5000) {
            guard let when = job.updatedAt, when >= start else { continue }
            let day = cal.startOfDay(for: when)
            if job.status == .applied { buckets[day, default: (0, 0)].0 += 1 }
            if job.status == .practiceComplete { buckets[day, default: (0, 0)].1 += 1 }
        }
        return (0..<days).map { offset in
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            let b = buckets[day] ?? (0, 0)
            return (day, b.0, b.1)
        }
    }
}

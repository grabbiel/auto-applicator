import Darwin
import Foundation

/// Keeps helper programs (the optional Ollama server) tied to the app's life.
///
/// Every helper is started through a tiny supervisor — the app's own executable run as
/// `AutoApplicator --supervise <app pid> -- <program> <args…>`. The supervisor puts the helper in its own process
/// group and watches the app with kqueue; when the app goes away for any reason (quit, crash, force quit) it stops the
/// whole group: SIGTERM, then SIGKILL after five seconds. Version 0.3 started helpers in new sessions and never
/// stopped them, so they kept running after quitting.
///
/// Each supervisor also notes its helper (pid and start time) in `registry`. If the app and its supervisor are killed
/// together (say, force-quitting both "AutoApplicator" entries in Activity Monitor), nothing is left to stop the
/// helper, so the next launch does it with `reapOrphans()`.
public enum Supervisor {
    public static let flag = "--supervise"

    /// Folder for the helper notes; nil turns them off.
    nonisolated(unsafe) public static var registry: URL?
    private static let registryVariable = "AA_SUPERVISOR_REGISTRY"

    /// The program that can run in supervisor mode (the app itself). Tests point this at a built copy.
    nonisolated(unsafe) public static var executable: URL? = Bundle.main.executableURL

    private static let lock = NSLock()
    nonisolated(unsafe) private static var children: [Process] = []

    /// Starts `program` under a supervisor that ends it when this process ends. Output goes to `log` if given.
    @discardableResult
    public static func launch(_ program: URL, arguments: [String], environment: [String: String] = [:], log: URL? = nil) throws -> Process {
        let p = Process()
        if let supervisor = executable {
            p.executableURL = supervisor
            p.arguments = [flag, String(getpid()), "--", program.path] + arguments
        } else {
            p.executableURL = program
            p.arguments = arguments
        }
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        if executable != nil, let registry { p.environment?[registryVariable] = registry.path }
        p.standardInput = FileHandle.nullDevice
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            handle.seekToEndOfFile()
            p.standardOutput = handle
            p.standardError = handle
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        try p.run()
        lock.lock()
        children.append(p)
        lock.unlock()
        return p
    }

    /// Stops every helper this process started (called when the app quits). Returns once they are gone or after
    /// `timeout`; the supervisors finish the job even if the app exits first.
    public static func terminateAll(timeout: TimeInterval = 3) {
        lock.lock()
        let list = children
        children.removeAll()
        lock.unlock()
        for p in list where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while list.contains(where: \.isRunning), Date() < deadline { usleep(50_000) }
    }

    public static func stop(_ p: Process) {
        if p.isRunning { p.terminate() }
        lock.lock()
        children.removeAll { $0 === p }
        lock.unlock()
    }

    /// Stops helpers whose supervisor is gone (they were adopted by launchd) and clears notes about helpers that have
    /// ended. A note only counts if the process's start time still matches, so a reused pid is never touched.
    /// Returns how many helper groups it stopped.
    @discardableResult
    public static func reapOrphans() -> Int {
        guard let registry, let names = try? FileManager.default.contentsOfDirectory(atPath: registry.path) else { return 0 }
        var stopped: [pid_t] = []
        for name in names {
            let note = registry.appendingPathComponent(name)
            let stamp = ((try? String(contentsOf: note, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = pid_t(name), pid > 1, let info = processInfo(pid), startStamp(info) == stamp else {
                try? FileManager.default.removeItem(at: note)
                continue
            }
            guard info.pbi_ppid == 1 else { continue }  // its supervisor is still watching it
            kill(-pid, SIGTERM)
            stopped.append(pid)
            try? FileManager.default.removeItem(at: note)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, stopped.contains(where: { kill(-$0, 0) == 0 }) { usleep(50_000) }
        for pid in stopped where kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        if !stopped.isEmpty { Log.warn("Stopped \(stopped.count) helper(s) left running by an earlier session.") }
        return stopped.count
    }

    static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func startStamp(_ info: proc_bsdinfo) -> String { "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)" }

    /// Supervisor mode. Never returns.
    public static func runSupervisor(_ argv: [String]) -> Never {
        guard let i = argv.firstIndex(of: flag), argv.count > i + 3, let parent = pid_t(argv[i + 1]), argv[i + 2] == "--" else {
            fputs("usage: \(flag) <parent pid> -- <program> [args…]\n", stderr)
            exit(64)
        }
        let command = Array(argv[(i + 3)...])
        // The note folder is for the supervisor only; the helper doesn't inherit it.
        let registryDir = getenv(registryVariable).map { String(cString: $0) }
        unsetenv(registryVariable)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        var child: pid_t = 0
        let cArgs = command.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        let rc = posix_spawn(&child, command[0], nil, &attr, cArgs, environ)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else {
            fputs("supervisor: couldn't start \(command[0]): \(String(cString: strerror(rc)))\n", stderr)
            exit(127)
        }

        var notePath: String?
        if let registryDir, let info = processInfo(child) {
            let path = registryDir + "/\(child)"
            try? FileManager.default.createDirectory(atPath: registryDir, withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: path, contents: Data(startStamp(info).utf8)) { notePath = path }
        }
        let note = notePath
        func finish(_ code: Int32) -> Never {
            if let note { unlink(note) }
            exit(code)
        }

        func stopGroup() -> Never {
            kill(-child, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            var status: Int32 = 0
            while Date() < deadline {
                if waitpid(child, &status, WNOHANG) == child, kill(-child, 0) != 0 { finish(0) }
                usleep(100_000)
            }
            kill(-child, SIGKILL)
            _ = waitpid(child, &status, 0)
            finish(0)
        }

        // The app asks politely with SIGTERM; forward it.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        let kq = kqueue()
        var changes = [
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
            kevent(ident: UInt(child), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT, data: 0, udata: nil),
            kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGINT), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGHUP), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil),
        ]
        _ = kevent(kq, &changes, Int32(changes.count), nil, 0, nil)
        // The app may have exited before the watch was set up.
        if kill(parent, 0) != 0 { stopGroup() }

        var event = kevent()
        while true {
            let n = kevent(kq, nil, 0, &event, 1, nil)
            if n < 0 { if errno == EINTR { continue }; stopGroup() }
            if n == 0 { continue }
            if event.filter == Int16(EVFILT_PROC) && event.ident == UInt(child) {
                var status: Int32 = 0
                _ = waitpid(child, &status, 0)
                kill(-child, SIGTERM)  // anything the helper left behind in its group
                let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                finish(code)
            }
            stopGroup()
        }
    }
}

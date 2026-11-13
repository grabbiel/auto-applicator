import Foundation
import UserNotifications

/// Daily runs through launchd. The agent only opens a link (`autoapplicator://scheduled-run?token=…`) that the app
/// answers; nothing runs in a terminal and nothing stays resident between runs. The token keeps web pages from
/// starting runs through the same link.
public enum Scheduler {
    public static let label = "io.github.grabbiel.autoapplicator.schedule"
    public static let urlScheme = "autoapplicator"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    public static func runURL(token: String) -> URL {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = "scheduled-run"
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        return c.url!
    }

    static func plist(_ schedule: Schedule, logs: URL) -> [String: Any] {
        let days: [Int?] = schedule.weekdaysOnly ? Array(1...5) : [nil]
        let calendar: [[String: Int]] = days.map { day in
            var d = ["Hour": schedule.hour, "Minute": schedule.minute]
            if let day { d["Weekday"] = day }
            return d
        }
        return [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", runURL(token: schedule.token).absoluteString],
            "StartCalendarInterval": calendar,
            "RunAtLoad": false,
            "ProcessType": "Interactive",
            "StandardOutPath": logs.appendingPathComponent("schedule.log").path,
            "StandardErrorPath": logs.appendingPathComponent("schedule.log").path,
        ]
    }

    public static func install(_ schedule: Schedule, paths: AppPaths) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist(schedule, logs: paths.logsDir), format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try data.write(to: agentURL, options: .atomic)
        let (status, output) = launchctl(["bootstrap", "gui/\(getuid())", agentURL.path])
        if status != 0 {
            throw BrowserError("Couldn't turn on the daily schedule (\(output.trimmed)).")
        }
        Log.info("Schedule on: \(schedule.summary)")
    }

    public static func remove() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: agentURL)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out)
    }
}

/// macOS notifications (only inside the app bundle; the command-line tests have none).
public enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    public static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(_ title: String, _ body: String, id: String = UUID().uuidString) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

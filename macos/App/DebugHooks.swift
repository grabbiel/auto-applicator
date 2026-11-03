import AppKit
import SwiftUI

/// Hooks for automated checks of the app's screens (scripts/ui_check.sh). Off unless AA_DEBUG_DIR is set: the app
/// then reads commands from $AA_DEBUG_DIR/commands.txt (one per line) and writes window pictures and state there.
@MainActor
enum DebugHooks {
    static func startIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["AA_DEBUG_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        let commands = folder.appendingPathComponent("commands.txt")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let text = try? String(contentsOf: commands, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: commands)
                for line in text.split(separator: "\n") { await perform(String(line), in: folder) }
            }
        }
    }

    private static func perform(_ line: String, in folder: URL) async {
        let model = AppModel.shared
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "snap":
            snapshot(to: folder.appendingPathComponent("\(arg).png"))
        case "size":
            let wh = arg.split(separator: " ").compactMap { Double($0) }
            if wh.count == 2, let window = NSApp.windows.first(where: \.isVisible) { window.setContentSize(NSSize(width: wh[0], height: wh[1])) }
        case "step":
            if let s = SetupStep(rawValue: arg) { model.furthest = max(model.furthest, s.index); model.step = s }
        case "page":
            if let p = Page(rawValue: arg) { model.page = p }
        case "next":
            await model.next()
        case "save":
            await model.save(thenFinish: false)
        case "finish":
            model.finishSetup()
        case "prepare":
            model.prepare()
        case "quit":
            NSApp.terminate(nil)
        case "resume":
            await model.useResume(URL(fileURLWithPath: arg))
        case "set":
            let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if kv.count == 2, let value = try? JSONDecoder().decode(JSON.self, from: Data(kv[1].utf8)) { model.set(kv[0], value) }
        case "test-email":
            await model.testEmail()
        case "answer":
            let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if kv.count == 2 { model.toast = await model.answer(kv[0], kv[1]) ?? "answered" }
        case "run":
            switch arg {
            case "practice": model.startRun(.practice)
            case "check": model.startRun(.checkSetup)
            default: break
            }
        case "stop-run":
            model.run?.stop()
        case "dump":
            let info: JSON = [
                "phase": .string(String(describing: model.phase)), "step": .string(model.step.rawValue),
                "page": .string(model.page.rawValue), "errors": .object(model.errors.mapValues(JSON.string)),
                "stepMessage": .string(model.stepMessage ?? ""), "toast": .string(model.toast ?? ""), "dirty": .bool(model.dirty),
                "draft": model.draft, "state": model.state, "run": .string(model.run?.output ?? ""),
            ]
            if let data = try? JSONEncoder().encode(info) { try? data.write(to: folder.appendingPathComponent("dump.json")) }
        default:
            break
        }
        try? "\(line)\n".appendLine(to: folder.appendingPathComponent("done.txt"))
    }

    /// Draws the app's own window into a PNG (no screen-recording permission needed).
    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: \.isVisible), let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(utf8))
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

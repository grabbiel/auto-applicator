import AppKit
import Engine
import SwiftUI

struct AutoApplicatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Auto Applicator", id: "main") {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        .commands { AppCommands(model: delegate.model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var finishedLaunching = false
    private var openedByLink = false
    private var quitting = false
    private var signalSource: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        // Opened by the daily schedule (not by the user): quit once the run is done, unless the user starts using it.
        if openedByLink { model.scheduledLaunch = true }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.scheduledLaunch = false }
        }
        // `kill`, logout and shutdown send SIGTERM: stop the helpers and save before exiting.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.model.shutdown() }
            exit(0)
        }
        source.resume()
        signalSource = source
        Task {
            await model.refreshLinkedIn()
            await model.ensureAI()
        }
        DebugHooks.runIfRequested(model)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        if !finishedLaunching { openedByLink = true }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.handle(url: url)
            // Opened by the schedule but no run started (an old link, setup unfinished…): nothing to do, so don't linger.
            if url.host == "scheduled-run", self.openedByLink, !NSApp.isActive, !self.model.isRunning { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        if model.isRunning && !model.scheduledLaunch {
            let alert = NSAlert()
            alert.messageText = "Stop applying and quit?"
            alert.informativeText = "A run is in progress. Quitting stops it right away; an application that isn't finished is not submitted."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Keep Running")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        quitting = true
        guard model.isRunning else {
            model.shutdown()
            return .terminateNow
        }
        Task {
            await model.stopRunAndWait()
            model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appTermination) {
            Button("Quit Auto Applicator") { model.quit() }.keyboardShortcut("q")
        }
        CommandMenu("Run") {
            Button(model.settings.practiceMode ? "Start Practice Run" : "Start Applying") {
                model.startRun(practice: model.settings.practiceMode)
            }
            .keyboardShortcut("r")
            .disabled(model.isRunning || !model.settings.setupComplete || !model.blockers.isEmpty)
            Button("Stop") { model.stopRun() }
                .keyboardShortcut(".")
                .disabled(!model.isRunning)
            Divider()
            Button("Watch Live") { model.page = .live }
                .keyboardShortcut("l")
                .disabled(!model.settings.setupComplete)
        }
        CommandGroup(replacing: .help) {
            Button("Show the Tour") {
                model.page = .home
                model.tourStep = 0
            }
            .disabled(!model.settings.setupComplete)
            Button("Open the Data Folder") { NSWorkspace.shared.open(model.paths.home) }
        }
    }
}

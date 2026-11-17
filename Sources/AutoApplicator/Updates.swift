import AppKit
import Engine
import SwiftUI

/// The app's side of updating itself (see Updater): a check 20 seconds after launch and every six hours (with automatic
/// updates on), the download, and installing — when the app quits, or right away with Restart now.
@MainActor @Observable
final class Updates {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        /// Downloaded and checked: installs when the app quits.
        case ready(UpdateInfo)
        case installing
        /// A newer version this copy can't install by itself (see Updater.cantReplace): its disk image, to open.
        case manual(UpdateInfo, URL, String)
        case failed(String)
    }

    var state: State = .idle
    var showDetails = false
    @ObservationIgnored private var staged: URL?
    @ObservationIgnored private var dmg: URL?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let folder: URL

    init(paths: AppPaths) {
        folder = paths.home.appendingPathComponent("updates", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)  // what an earlier session left
    }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// The app on disk; nil for a development build (not an app bundle), which never updates itself.
    static var installed: URL? { AppModel.thisApp }

    /// A newer version to tell the person about.
    var offer: UpdateInfo? {
        switch state {
        case .ready(let info), .manual(let info, _, _): info
        default: nil
        }
    }

    var busy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    func start(automatic: @escaping @MainActor () -> Bool) {
        guard Self.installed != nil, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                if automatic() { await self?.check() }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Looks for a newer version and gets it ready. Returns what to tell someone who asked.
    @discardableResult
    func check() async -> String {
        guard let installed = Self.installed else { return "This is a development build; it doesn't update itself." }
        if busy { return "Already checking." }
        if let offer { return "Version \(offer.version) is ready." }
        state = .checking
        do {
            guard let info = try await Updater.check(current: Self.current) else {
                state = .upToDate
                return "You have the newest version (\(Self.current))."
            }
            Log.info("Version \(info.version) is out; downloading it")
            state = .downloading(info.version)
            let dmg = try await Updater.download(info, into: folder)
            self.dmg = dmg
            if let why = Updater.cantReplace(installed) {
                state = .manual(info, dmg, why)
                return "Version \(info.version) is out."
            }
            staged = try await Task.detached { try Updater.stage(dmg: dmg, info: info, installed: installed) }.value
            state = .ready(info)
            Log.info("Version \(info.version) is ready; it installs when the app quits")
            return "Version \(info.version) is ready."
        } catch {
            Log.warn("Update: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// Installs the downloaded version and opens it again.
    func restartNow(_ model: AppModel) {
        guard case .ready(let info) = state, !model.isRunning, let installed = Self.installed else { return }
        guard install(info, over: installed) else { return }
        Updater.relaunch(installed, after: ProcessInfo.processInfo.processIdentifier)
        model.quit()
    }

    /// Called as the app quits: installs a downloaded version, so the next launch is the new one.
    func installOnQuit() {
        guard case .ready(let info) = state, let installed = Self.installed else { return }
        _ = install(info, over: installed)
    }

    private func install(_ info: UpdateInfo, over installed: URL) -> Bool {
        guard let staged else { return false }
        state = .installing
        do {
            try Updater.install(staged: staged, over: installed)
            self.staged = nil
            if let dmg { try? FileManager.default.removeItem(at: dmg) }
            return true
        } catch {
            Log.warn("Update: \(error.localizedDescription)")
            if let dmg { state = .manual(info, dmg, error.localizedDescription) } else { state = .failed(error.localizedDescription) }
            return false
        }
    }

    func openDiskImage() {
        if case .manual(_, let dmg, _) = state { NSWorkspace.shared.open(dmg) }
    }
}

// MARK: - views

/// In the top bar while a new version waits: opens what's new and Restart now.
struct UpdateChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        if let offer = updates.offer {
            Button { updates.showDetails.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.green)
                    Text("Update").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.text)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Palette.greenWash, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.green.opacity(0.45)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Version \(offer.version) is ready")
            .popover(isPresented: $updates.showDetails, arrowEdge: .bottom) {
                UpdateDetails().environment(model).frame(width: 340).padding(18)
            }
        }
    }
}

/// What the new version brings and how it gets installed.
struct UpdateDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.updates
        if let offer = updates.offer {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Version \(offer.version)").font(Typo.heading(17))
                    Text("You have \(Updates.current).").font(Typo.small).foregroundStyle(Palette.textSoft)
                }
                if let notes = offer.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(notes.prefix(6).enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle().fill(Palette.green).frame(width: 5, height: 5).offset(y: -2)
                                Text(note).font(Typo.small).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let page = offer.page {
                    Link("What's new, in full", destination: page).font(Typo.small.weight(.semibold)).foregroundStyle(Palette.greenDeep)
                }
                Divider().overlay(Palette.line)
                if case .manual(_, _, let why) = updates.state {
                    Text(why).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                    Button("Open the disk image") { updates.openDiskImage() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Text(model.isRunning
                         ? "It installs when the app quits, or restart once this run is done. Your data stays as it is."
                         : "It installs when the app quits. Your data stays as it is.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Restart now") { updates.restartNow(model) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.isRunning || updates.state == .installing)
                        Button("Later") { updates.showDetails = false }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }
}

/// The Updates card in Settings.
struct UpdatesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let updates = model.updates
        ToggleRow(title: "Keep the app up to date",
                  detail: "Looks for a new version every few hours, downloads it, and installs it the next time the app quits. Your data stays as it is.",
                  isOn: $model.settings.autoUpdate)
        Divider().overlay(Palette.line)
        HStack(alignment: .center, spacing: 10) {
            status(updates.state)
            Spacer(minLength: 12)
            if updates.busy {
                ProgressView().controlSize(.small)
            } else if updates.offer != nil {
                Button("Details") { model.page = .settings; updates.showDetails = true }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Check now") { Task { model.show(await updates.check(), symbol: "arrow.down.circle.fill") } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(Updates.installed == nil)
            }
        }
    }

    @ViewBuilder private func status(_ state: Updates.State) -> some View {
        let (title, detail): (String, String) = switch state {
        case .idle: ("Version \(Updates.current)", Updates.installed == nil ? "A development build: it doesn't update itself." : "Not checked yet.")
        case .checking: ("Version \(Updates.current)", "Checking for a new version…")
        case .upToDate: ("Version \(Updates.current)", "The newest version.")
        case .downloading(let v): ("Downloading version \(v)…", "You can keep using the app.")
        case .ready(let info): ("Version \(info.version) is ready", "It installs when the app quits. The Update button at the top restarts now.")
        case .installing: ("Installing…", "The app opens again in a moment.")
        case .manual(let info, _, let why): ("Version \(info.version) is out", why)
        case .failed(let why): ("Version \(Updates.current)", why)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.bodyStrong)
            Text(detail).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
        }
    }
}

import AdminKit
import AppKit
import SwiftUI

/// The owner's own tool for the cloud browser's AWS side: who is invited, what each of them has and uses, and the
/// stack underneath. It runs on the owner's Mac with their administrator AWS sign-in and is never shipped: everything
/// it changes, it changes by running scripts/deploy_cloud.sh.
@main
struct AutoApplicatorAdminApp: App {
    @NSApplicationDelegateAdaptor(AdminDelegate.self) private var delegate

    var body: some Scene {
        Window("Auto Applicator Admin", id: "main") {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 980, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await delegate.model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

@MainActor
final class AdminDelegate: NSObject, NSApplicationDelegate {
    let model = AdminModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await model.refresh()
            await Snapshots.takeIfRequested(model)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @Environment(AdminModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            tabs
            Divider().overlay(Palette.line)
            if let problem = model.problem { ProblemBanner(problem: problem) }
            ScrollView {
                Group {
                    switch model.tab {
                    case .people: PeopleView()
                    case .cloud: CloudView()
                    case .activity: ActivityView()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            Divider().overlay(Palette.line)
            statusBar
        }
        .background(Palette.canvas)
        .alert(model.confirm?.title ?? "", isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }),
               presenting: model.confirm) { confirmation in
            Button(confirmation.button, role: .destructive) { Task { await confirmation.action() } }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(isPresented: $model.showSettings) { SettingsSheet() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.green)
                Image(systemName: "cloud.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            Text("Auto Applicator").font(Typo.display(18)).foregroundStyle(Palette.ink)
            Pill(text: "Admin", tone: .green)
            if model.demo { Pill(text: "Demo", tone: .amber) }
            Spacer()
            if let snapshot = model.snapshot {
                Text("AWS \(snapshot.account) · \(model.settings.profile) · \(model.settings.region)")
                    .font(Typo.small).foregroundStyle(Palette.textSoft).textSelection(.enabled)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 5) {
                    if model.loading { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)) }
                    Text("Refresh")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.loading || model.working)
            Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(SecondaryButtonStyle())
                .help("Which AWS profile, region, stack and project folder")
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(AdminModel.Tab.allCases, id: \.self) { tab in
                Button { model.tab = tab } label: {
                    VStack(spacing: 7) {
                        HStack(spacing: 5) {
                            Text(tab.rawValue).font(.system(size: 14, weight: model.tab == tab ? .heavy : .semibold))
                                .foregroundStyle(model.tab == tab ? Palette.ink : Palette.textSoft)
                            if tab == .people, !model.people.isEmpty {
                                Text("\(model.people.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.greenDeep)
                            }
                        }
                        Rectangle().fill(model.tab == tab ? Palette.green : .clear).frame(height: 3)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(Typo.small).foregroundStyle(Palette.text)
            } else if let note = model.note {
                Image(systemName: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(note.ok ? Palette.greenDeep : Palette.red)
                Text(note.text).font(Typo.small).foregroundStyle(Palette.text).lineLimit(2).textSelection(.enabled)
            } else if model.demo {
                Text("Made-up people: nothing here touches AWS.").font(Typo.small).foregroundStyle(Palette.textFaint)
            } else if let read = model.snapshot?.read {
                Text("Read from AWS \(read.ago).").font(Typo.small).foregroundStyle(Palette.textFaint)
            }
            Spacer()
            if model.note != nil, model.busy == nil, model.tab != .activity {
                Button("See what ran") { model.tab = .activity }.buttonStyle(.plain).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.greenDeep)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 38)
        .background(Palette.sunken)
    }
}

/// Why AWS can't be read, and what gets it going again.
struct ProblemBanner: View {
    @Environment(AdminModel.self) private var model
    var problem: AdminError

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.localizedDescription).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if problem == .signedOut {
                    Text("Sign in opens your browser to approve it (profile \(model.settings.profile)). What's below is from the last time AWS could be read.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if problem == .signedOut {
                Button("Sign in to AWS") { Task { await model.signIn() } }.buttonStyle(PrimaryButtonStyle()).disabled(model.working)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(Palette.amberWash)
    }
}

/// Which AWS sign-in, region and stack, and where the project is.
struct SettingsSheet: View {
    @Environment(AdminModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AdminSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where the cloud is").font(Typo.heading(17)).foregroundStyle(Palette.ink)
            Text("The same values scripts/deploy_cloud.sh uses (AWS_PROFILE, AWS_REGION, AA_STACK).")
                .font(Typo.small).foregroundStyle(Palette.textSoft)
            field("AWS profile", $draft.profile)
            field("Region", $draft.region)
            field("Stack", $draft.stack)
            field("Project folder", $draft.repo)
            HStack {
                Button("Choose folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { draft.repo = url.path }
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") {
                    model.settings = draft
                    dismiss()
                    Task { await model.refresh() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { draft = model.settings }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Typo.small).foregroundStyle(Palette.textSoft).frame(width: 100, alignment: .leading)
            TextField("", text: text).textFieldStyle(.roundedBorder).font(Typo.body)
        }
    }
}

/// AA_ADMIN_SNAPSHOTS=<folder>: saves a picture of each tab there and quits (to check the look; use with AA_ADMIN_DEMO=1).
@MainActor
enum Snapshots {
    static func takeIfRequested(_ model: AdminModel) async {
        guard let folder = ProcessInfo.processInfo.environment["AA_ADMIN_SNAPSHOTS"], !folder.isEmpty else { return }
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if model.demo {
            model.expanded = [model.people.first?.id ?? ""]
            await model.lookUpCost()
        }
        // Tall enough to show a whole tab without scrolling.
        NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 980, height: 1560))
        for tab in AdminModel.Tab.allCases {
            model.tab = tab
            try? await Task.sleep(for: .milliseconds(700))
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("admin-\(tab.rawValue.lowercased()).png"))
        }
        NSApp.terminate(nil)
    }
}

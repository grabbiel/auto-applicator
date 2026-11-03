import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .checking: BusyScreen(text: "Opening Auto Applicator…")
            case .starting: BusyScreen(text: "Starting…")
            case .welcome: WelcomeScreen()
            case .preparing: PreparingScreen()
            case .failed(let message): FailedScreen(message: message)
            case .setup: SetupWizard()
            case .main: MainView()
            }
        }
        .frame(minWidth: 880, minHeight: 640)
        .overlay(alignment: .bottom) { ToastView().animation(.easeInOut(duration: 0.2), value: model.toast) }
        .overlay { if model.helperStopped { HelperStoppedView() } }
        .onAppear { model.launch() }
    }
}

struct BusyScreen: View {
    let text: String
    var body: some View {
        VStack(spacing: 18) {
            AppIcon(size: 88)
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WelcomeScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            AppIcon(size: 104)
            Text("Welcome to Auto Applicator").font(.system(size: 30, weight: .bold))
            Text("It finds jobs on LinkedIn that match what you want and fills in the applications for you, using an AI that runs privately on this Mac.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            VStack(alignment: .leading, spacing: 14) {
                PlanRow(number: 1, title: "It downloads what it needs", detail: "About 6 GB in total – 10 to 20 minutes, depending on your internet. You can fill in your details meanwhile.")
                PlanRow(number: 2, title: "You add your resume and choose the jobs you want", detail: "It can read your resume and fill in your details for you.")
                PlanRow(number: 3, title: "You sign in to LinkedIn once", detail: "Then a practice run shows you what it would send, without sending anything.")
            }
            .frame(maxWidth: 540)
            .padding(.vertical, 6)
            HStack(spacing: 12) {
                Button("Not now") { NSApp.terminate(nil) }.controlSize(.large)
                Button("Set up") { model.prepare() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            Label("Your details stay on this Mac.", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlanRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PreparingScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            AppIcon(size: 96)
            Text("Setting up Auto Applicator").font(.system(size: 26, weight: .bold))
            ProgressView(value: model.prepProgress).frame(width: 380)
            Text(model.prepMessage).foregroundStyle(.secondary)
            Text("This takes a minute or two. You can keep using your Mac.").font(.callout).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedScreen: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 54)).foregroundStyle(.orange)
            Text("Something went wrong").font(.system(size: 26, weight: .bold))
            Text(message)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 560)
            HStack(spacing: 12) {
                Button("Show details") { NSWorkspace.shared.open(model.paths.logs) }.controlSize(.large)
                Button("Try again") { model.prepare() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HelperStoppedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
                Text("Part of Auto Applicator stopped").font(.title2.bold())
                Text("Your typing is kept. Restart it to carry on.").foregroundStyle(.secondary)
                Button("Restart") { model.restartHelper() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(30)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

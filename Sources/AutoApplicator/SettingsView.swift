import AppKit
import Engine
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmForget = false
    @State private var showPassword = false

    var body: some View {
        @Bindable var model = model
        Page(title: "Settings", subtitle: "How and when it applies, and the accounts it uses.") {
            card("Applying", "paperplane") {
                ToggleRow(title: "Practice mode",
                          detail: "Fills every form but stops before the final Submit. Turn it off when you're happy with its work.",
                          isOn: $model.settings.practiceMode)
                Divider().overlay(Palette.line)
                HStack {
                    Text("Applications per run").font(Typo.bodyStrong)
                    Spacer()
                    Stepper(value: $model.settings.limits.maxAppliesPerRun, in: 1...50) {
                        Text("\(model.settings.limits.maxAppliesPerRun)").font(Typo.number(15)).frame(minWidth: 28)
                    }
                }
            }

            card("Daily schedule", "calendar.badge.clock") {
                ToggleRow(title: "Run every day by itself",
                          detail: "At the time below, the app opens in the background, runs, sends you a notification, and quits. Your Mac needs to be on and you need to be logged in.",
                          isOn: $model.settings.schedule.enabled)
                if model.settings.schedule.enabled {
                    HStack(spacing: 16) {
                        DatePicker("Time", selection: scheduleTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                            .frame(width: 170)
                        Segmented(options: [true, false], selection: $model.settings.schedule.weekdaysOnly, title: { $0 ? "Weekdays" : "Every day" })
                            .frame(width: 220)
                        Spacer()
                    }
                }
            }
            .onChange(of: model.settings.schedule) { model.applySchedule() }

            card("AI helper", "sparkles") { AIStatusView() }

            card("LinkedIn", "person.badge.key") { LinkedInStatusView() }

            if model.cloudAvailable {
                card("Cloud browser", "cloud") { CloudBrowserView() }
            }

            card("Email codes", "envelope.badge") { EmailSetupView() }

            card("Company-site accounts", "key") {
                Text("Some company sites (like Workday) make you create an account to apply. It uses this password for those accounts, so you can sign in to them yourself later.")
                    .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(showPassword ? model.secrets.portalPassword : String(repeating: "•", count: 16))
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 6))
                    Button(showPassword ? "Hide" : "Show") { showPassword.toggle() }.buttonStyle(SecondaryButtonStyle())
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.secrets.portalPassword, forType: .string)
                        model.show("Password copied.")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            card("Your data", "externaldrive") {
                Text(model.usesCloud
                     ? "Your profile, resume, answers and a PDF of every application stay on this Mac, in one folder. The cloud browser keeps only its cookies, in your AWS account."
                     : "Everything stays on this Mac, in one folder: your profile, resume, answers and a PDF of every application.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(Typo.small).foregroundStyle(Palette.textSoft)
                HStack(spacing: 8) {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.paths.home) }.buttonStyle(SecondaryButtonStyle())
                    Button("Replay the tour") { model.page = .home; model.tourStep = 0 }.buttonStyle(SecondaryButtonStyle())
                    Button("Run setup again") { model.restartSetup() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Forget learned answers…") { confirmForget = true }.buttonStyle(QuietButtonStyle(color: Palette.red))
                }
            }

            HStack {
                BrandMark(size: 22)
                Text("Auto Applicator \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(Typo.small).foregroundStyle(Palette.textFaint)
                Spacer()
            }
            .padding(.top, 4)
        }
        .alert("Forget every learned answer?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                for a in model.learned { model.forget(a) }
                model.show("Learned answers cleared.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile and facts stay. Questions you answered will be asked again.")
        }
    }

    private var scheduleTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: model.settings.schedule.hour, minute: model.settings.schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            model.settings.schedule.hour = c.hour ?? 9
            model.settings.schedule.minute = c.minute ?? 30
        })
    }

    private func card(_ title: String, _ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.green).frame(width: 18)
                    Text(title).font(Typo.heading(17))
                }
                content()
            }
        }
    }
}

// MARK: - shared with onboarding

struct AIStatusView: View {
    @Environment(AppModel.self) private var model
    var showEngineChoice = true

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            switch model.aiState {
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(Typo.body) }
            case .ready(let name):
                statusLine("checkmark.circle.fill", .green, "Ready: \(name)", "Runs privately on this Mac. Nothing you type is sent anywhere.")
            case .needsSetup(let why):
                statusLine("exclamationmark.circle.fill", .amber, "Not set up yet", why)
                setupButtons
            case .working(let label, let progress):
                VStack(alignment: .leading, spacing: 8) {
                    Text(label).font(Typo.bodyStrong)
                    if let progress {
                        ProgressView(value: progress).tint(Palette.green)
                        Text("\(Int(progress * 100))%  ·  You can keep using the app.").font(Typo.small).foregroundStyle(Palette.textSoft)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            case .failed(let message):
                statusLine("xmark.octagon.fill", .red, "The AI helper didn't start", message)
                HStack {
                    Button("Try again") { model.resetAI() }.buttonStyle(SecondaryButtonStyle())
                    setupButtons
                }
            }
            if showEngineChoice {
                Divider().overlay(Palette.line)
                HStack {
                    Text("Engine").font(Typo.bodyStrong)
                    Spacer()
                    Picker("", selection: $model.settings.ai.engine) {
                        Text("Automatic").tag(AIEngineChoice.automatic)
                        Text("Apple Intelligence").tag(AIEngineChoice.apple)
                        Text("Ollama (downloaded model)").tag(AIEngineChoice.ollama)
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .onChange(of: model.settings.ai.engine) { model.resetAI() }
                }
            }
        }
    }

    @ViewBuilder private var setupButtons: some View {
        HStack(spacing: 8) {
            if AppleIntelligence.status == .notEnabled || AppleIntelligence.status == .notReady {
                Button("Open Apple Intelligence settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Check again") { model.resetAI() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Download the AI (\(model.ollamaDownloadSize))") { Task { await model.setUpOllama() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func statusLine(_ symbol: String, _ tone: Tone, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tone.color).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.bodyStrong)
                Text(detail).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LinkedInStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x0A66C2))
                Text("in").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                switch model.linkedInState {
                case .signedIn:
                    Text("Signed in").font(Typo.bodyStrong)
                    Text("It searches and applies as you.").font(Typo.small).foregroundStyle(Palette.textSoft)
                case .signedOut:
                    Text("Not signed in").font(Typo.bodyStrong)
                    Text("Sign in once. You type your password on LinkedIn's own page; the app never sees it.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                case .unknown:
                    Text("Checking…").font(Typo.bodyStrong)
                }
            }
            Spacer()
            if model.linkedInState == .signedIn {
                Button("Sign out") { Task { await model.signOutOfLinkedIn() } }.buttonStyle(SecondaryButtonStyle()).disabled(model.isRunning)
            } else {
                Button("Sign in to LinkedIn") { model.showSignIn = true }.buttonStyle(PrimaryButtonStyle()).disabled(model.isRunning)
            }
        }
    }
}

struct EmailSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Some company sites email a code before you can apply. With access to your inbox, it reads the code and types it in. It only looks at the last few minutes of mail, and only during a run.")
                .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                Field(label: "Email address") {
                    TextInput("you@gmail.com", text: $model.secrets.imapUser)
                        .onChange(of: model.secrets.imapUser) { _, new in
                            if let host = EmailProviders.host(for: new) { model.secrets.imapHost = host }
                        }
                }
                Field(label: "App password", hint: "Not your normal password: a special one for apps (see below).") {
                    TextInput("xxxx xxxx xxxx xxxx", text: $model.secrets.imapPassword, secure: true)
                }
            }
            if let guide = EmailProviders.guide(for: model.secrets.imapUser) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to get an app password for \(guide.name)").font(Typo.bodyStrong)
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                                .frame(width: 18, height: 18).background(Palette.green, in: Circle())
                            Text(LocalizedStringKey(step)).font(Typo.small).foregroundStyle(Palette.textSoft).tint(Palette.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if model.secrets.imapUser.contains("@") {
                Field(label: "Mail server (IMAP)", hint: "Your provider's help pages list it, e.g. imap.example.com.") {
                    TextInput("imap.example.com", text: $model.secrets.imapHost)
                }
            }
            HStack(spacing: 10) {
                Button { Task { await model.testEmail() } } label: {
                    if model.emailTesting { ProgressView().controlSize(.small) } else { Text("Test connection") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.secrets.imapUser.contains("@") || model.secrets.imapPassword.isEmpty || model.emailTesting)
                if let test = model.emailTest {
                    Label(test.message, systemImage: test.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(Typo.small).foregroundStyle(test.ok ? Palette.greenDeep : Palette.red).lineLimit(3)
                }
            }
        }
    }
}

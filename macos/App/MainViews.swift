import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                PageButton(page: .home, title: "Home", symbol: "house")
                PageButton(page: .questions, title: "Questions", symbol: "questionmark.bubble", badge: model.pendingCount)
                PageButton(page: .results, title: "Results", symbol: "list.bullet.rectangle")
                PageButton(page: .details, title: "My details & job search", symbol: "person.text.rectangle")
                Spacer()
            }
            .padding(12)
            .frame(width: 220)
            .background(SidebarBackground())
            Divider()
            Group {
                switch model.page {
                case .home: HomeView()
                case .questions: QuestionsView()
                case .results: ResultsView()
                case .details: DetailsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { InstallPill() } }
    }
}

struct PageButton: View {
    @EnvironmentObject var model: AppModel
    let page: Page
    let title: String
    let symbol: String
    var badge = 0

    var body: some View {
        let selected = model.page == page
        Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title).fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel

    private var practiceMode: Bool { model.draft["search.dry_run"].bool ?? true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.firstName.isEmpty ? "Welcome back" : "Hi, \(model.firstName)").font(.system(size: 28, weight: .bold))
                    Text("Auto Applicator searches LinkedIn for the jobs you want and fills in the applications.").foregroundStyle(.secondary)
                }
                if model.pendingCount > 0 {
                    Card {
                        HStack {
                            Image(systemName: "questionmark.bubble.fill").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text(model.pendingCount == 1 ? "1 question is waiting for your answer" : "\(model.pendingCount) questions are waiting for your answer")
                                    .font(.headline)
                                Text("Jobs that asked them were skipped. Answer once and they're tried again next time.").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Answer them") { model.page = .questions }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                Card {
                    Text("Apply").font(.title3.bold())
                    HStack(alignment: .top, spacing: 14) {
                        ActionButton(title: "Start a practice run", detail: "Fills in applications without sending them.",
                                     symbol: "play.fill", prominent: true) { model.startRun(.practice) }
                        ActionButton(title: "Apply for real…", detail: "Sends up to \(model.draft["search.max_applies_per_run"].text) applications.",
                                     symbol: "paperplane.fill", prominent: false) { model.confirmLiveRun() }
                    }
                    .disabled(model.runActive || model.signingIn || !model.installDone)
                    if !model.installDone {
                        Text("Available as soon as the installation finishes (see the top right).").foregroundStyle(.secondary)
                    } else if !model.signedIn {
                        Label("Sign in to LinkedIn first (below).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                if let run = model.run {
                    RunView(session: run)
                }
                Card {
                    Text("Status").font(.title3.bold())
                    StatusLine(ok: model.signedIn, title: "LinkedIn", detail: model.signedIn ? "Signed in" : "Not signed in yet") {
                        Button(model.signedIn ? "Sign in again" : "Sign in") { model.signIn() }
                            .disabled(model.signingIn || !model.browserReady || model.runActive)
                    }
                    if model.signingIn {
                        BannerView(.info, model.state["linkedin"]["message"].text, spinning: true)
                    }
                    Divider()
                    let emailOK = model.state["email_configured"].bool == true
                    StatusLine(ok: emailOK, title: "Email codes", detail: emailOK ? "Set up" : "Not set up – jobs that email a code are skipped") {
                        Button(emailOK ? "Test" : "Set up") {
                            if emailOK { model.startRun(.testEmail) } else { model.step = .email; model.page = .details }
                        }
                        .disabled(model.runActive && emailOK)
                    }
                    Divider()
                    StatusLine(ok: practiceMode ? nil : true, title: "Practice mode",
                               detail: practiceMode ? "On – applications are filled in but not sent" : "Off – scheduled runs send applications") {
                        Button("Change") { model.step = .jobs; model.page = .details }
                    }
                    Divider()
                    let scheduled = model.state["schedule"].text
                    StatusLine(ok: scheduled.isEmpty ? nil : true, title: "Daily schedule", detail: scheduled.isEmpty ? "Off" : "Runs \(scheduled)") {
                        Toggle("", isOn: Binding(get: { !scheduled.isEmpty }, set: { model.setSchedule($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                HStack(spacing: 10) {
                    Button { model.startRun(.checkSetup) } label: { Label("Check setup", systemImage: "stethoscope") }
                        .disabled(model.runActive)
                    Button { model.open(model.paths.screenshots) } label: { Label("Practice-run pictures", systemImage: "photo.on.rectangle") }
                    Button { model.open(model.paths.support) } label: { Label("Settings folder", systemImage: "folder") }
                    Spacer()
                    Text("Version \(model.version)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ActionButton: View {
    let title: String
    let detail: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .modifier(ProminentIf(prominent))
    }
}

private struct ProminentIf: ViewModifier {
    let on: Bool
    init(_ on: Bool) { self.on = on }
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

struct StatusLine<Accessory: View>: View {
    let ok: Bool?
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok == true ? Color.green : ok == false ? Color.orange : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

struct RunView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: RunSession

    var body: some View {
        Card {
            HStack(spacing: 10) {
                if session.isRunning { ProgressView().controlSize(.small) } else {
                    Image(systemName: session.exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(session.exitCode == 0 ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.kind.title).font(.title3.bold())
                    Text(session.statusText).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isRunning {
                    Button(role: .destructive) { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .disabled(session.stopRequested)
                } else {
                    if session.kind == .practice || session.kind == .live {
                        Button("Show results") { model.page = .results }
                    }
                    if session.kind == .practice {
                        Button("See the pictures") { model.open(model.paths.screenshots) }
                    }
                    Button("Close") { model.run = nil }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? "Starting…" : session.output)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 300)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: session.output) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            if session.isRunning {
                Text("A browser window opens while it works. You can keep using your Mac, but leave that window alone.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct QuestionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Questions").font(.system(size: 28, weight: .bold))
                Text("When an application asks something your details don't cover, Auto Applicator skips that job instead of guessing, and asks you here. Your answer is saved, used from now on, and the job is tried again on the next run.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.questions.isEmpty {
                    Card {
                        Label("No questions are waiting for you.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.headline)
                    }
                }
                ForEach(Array(model.questions.enumerated()), id: \.element["hash"].text) { _, q in
                    QuestionCard(question: q)
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await model.loadQuestions() }
    }
}

struct QuestionCard: View {
    @EnvironmentObject var model: AppModel
    let question: JSON
    @State private var answer = ""
    @State private var error: String?
    @State private var busy = false

    private var options: [String] { question["options"].strings }
    private var hash: String { question["hash"].text }

    var body: some View {
        Card {
            Text(question["question"].text).font(.headline).fixedSize(horizontal: false, vertical: true)
            let companies = question["companies"].strings
            if !companies.isEmpty {
                Text("Asked by: " + companies.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            }
            if options.isEmpty {
                TextField("Your answer", text: $answer, prompt: Text(question["field_type"].string == "number" ? "A number, e.g. 3" : "Your answer"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
            } else if options.count <= 6 {
                Picker("Your answer", selection: $answer) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } else {
                Picker("Your answer", selection: $answer) {
                    Text("Choose…").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 420)
            }
            if let error { ErrorText(error) }
            HStack {
                Button("Save answer") {
                    busy = true
                    Task {
                        error = await model.answer(hash, answer)
                        busy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Button("Don't ask again") { Task { await model.dismiss(hash) } }
                    .help("Forget this question. Jobs that ask it will be skipped again.")
            }
        }
    }
}

struct JobRow: Identifiable {
    let id: String
    let when: String
    let company: String
    let title: String
    let result: String
    let notes: String
    let url: String
}

struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<String>()

    private var rows: [JobRow] {
        model.results["jobs"].array.map {
            JobRow(id: $0["id"].text, when: $0["when"].text, company: $0["company"].text, title: $0["title"].text,
                   result: $0["label"].text, notes: $0["notes"].text, url: $0["url"].text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Results").font(.system(size: 28, weight: .bold))
                Spacer()
                Button { Task { await model.loadResults() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { model.open(model.paths.screenshots) } label: { Label("Practice-run pictures", systemImage: "photo.on.rectangle") }
            }
            let counts = model.results["counts"].array
            if counts.isEmpty {
                Text("Nothing yet. Start a practice run on the Home page.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(counts.enumerated()), id: \.offset) { _, c in
                        Text("\(c["count"].text)  \(c["label"].text)")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
            Table(rows, selection: $selection) {
                TableColumn("When") { Text($0.when).monospacedDigit() }.width(min: 110, ideal: 125)
                TableColumn("Company", value: \.company).width(min: 100, ideal: 150)
                TableColumn("Job", value: \.title).width(min: 140, ideal: 220)
                TableColumn("Result", value: \.result).width(min: 140, ideal: 200)
                TableColumn("Notes") { Text($0.notes).help($0.notes) }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Open the job on LinkedIn") { openJobs(ids) }.disabled(ids.isEmpty)
            } primaryAction: { ids in
                openJobs(ids)
            }
            Text("Double-click a row to open the job.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .task { await model.loadResults() }
    }

    private func openJobs(_ ids: Set<String>) {
        for row in rows where ids.contains(row.id) {
            if let url = URL(string: row.url), url.scheme?.hasPrefix("http") == true { NSWorkspace.shared.open(url) }
        }
    }
}

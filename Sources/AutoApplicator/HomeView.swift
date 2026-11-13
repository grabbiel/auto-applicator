import Charts
import Engine
import SwiftUI

/// Today, laid out like Naver's home: the content on the left, the start box and small status widgets on the right.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReal = false

    var body: some View {
        Page(title: greeting, subtitle: subtitle) {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 16) {
                    stats
                    activityCard
                    suggestions
                    if !model.runs.isEmpty { recentRuns }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    startBox
                    knowledgeWidget
                    scheduleWidget
                    connectionsWidget
                }
                .frame(width: 320)
            }
        }
        .alert("Send applications for real?", isPresented: $confirmReal) {
            Button("Start applying") { model.startRun(practice: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will press Submit on up to \(model.settings.limits.maxAppliesPerRun) applications. Each one is saved as a PDF under Applications so you can see exactly what was sent.")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return model.firstName.isEmpty ? part : "\(part), \(model.firstName)"
    }

    private var subtitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        let pending = model.pending.count
        let tail = pending > 0 ? " · \(pending) question\(pending == 1 ? "" : "s") waiting for you" : ""
        return f.string(from: Date()) + tail
    }

    // MARK: start box

    /// Naver's sign-in box: one line, one big green button, small links under it.
    private var startBox: some View {
        @Bindable var model = model
        return Card(padding: 18) {
            VStack(spacing: 14) {
                if model.isRunning {
                    HStack(spacing: 8) {
                        PulsingDot(color: Palette.red)
                        Text(model.runPhase.isEmpty ? "Working on it…" : model.runPhase)
                            .font(.system(size: 13.5, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    Button { model.page = .live } label: {
                        Label("Watch live", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true, fill: true))
                    .tourAnchor("home.start")
                    LinkBar(items: [
                        .init(title: "\(model.outcomes.count) done so far") { model.page = .live },
                        .init(title: "Stop") { model.stopRun() },
                    ])
                } else {
                    Text(model.settings.practiceMode ? "Fill applications without sending them" : "Fill and send applications")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity)
                    Segmented(options: [true, false], selection: $model.settings.practiceMode, title: { $0 ? "Practice" : "Send for real" })
                    let blockers = model.blockers
                    Button {
                        if model.settings.practiceMode { model.startRun(practice: true) } else { confirmReal = true }
                    } label: {
                        Label(model.settings.practiceMode ? "Start practice run" : "Start applying", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(large: true, fill: true))
                    .disabled(!blockers.isEmpty)
                    .tourAnchor("home.start")
                    ForEach(blockers) { b in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.amber).font(.system(size: 12))
                            Text(b.message).font(Typo.small).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(b.fixTitle) { b.fix() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    if blockers.isEmpty, case .needsSetup = model.aiState {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "info.circle").foregroundStyle(Palette.textSoft).font(.system(size: 12))
                            Text("No AI helper yet: it will use only the answers you've given it.").font(Typo.small).foregroundStyle(Palette.textSoft)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Set up") { model.page = .settings }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    LinkBar(items: [
                        .init(title: "Job search") { model.page = .search },
                        .init(title: "Applications") { model.page = .applications },
                        .init(title: "Tour") { model.tourStep = 0 },
                    ])
                }
                Text(searchLine)
                    .font(Typo.small).foregroundStyle(Palette.textSoft).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                if model.usesCloud {
                    Label("Runs in your cloud browser", systemImage: "cloud.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.blue)
                }
            }
        }
    }

    private var searchLine: String {
        let titles = model.settings.search.cleanKeywords
        guard !titles.isEmpty else { return "Tell it which jobs to look for, and it searches LinkedIn and fills in the applications for you." }
        let quoted = ListFormatter.localizedString(byJoining: titles.prefix(3).map { "“\($0)”" }) + (titles.count > 3 ? " and \(titles.count - 3) more" : "")
        let place = [model.settings.search.location] + model.settings.search.workplace.map(\.rawValue)
        return "Looks for \(quoted) in \(place.filter { !$0.isEmpty }.joined(separator: " · ")), up to \(model.settings.limits.maxAppliesPerRun) per run."
    }

    // MARK: widgets

    /// How much it knows, shown like Naver's weather: a big figure and what to do about it.
    private var knowledgeWidget: some View {
        let score = model.knowledge.score
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                widgetHeader("What it knows") { MoreLink(title: "Teach it") { model.page = .knowledge } }
                HStack(spacing: 16) {
                    ZStack {
                        ProgressRing(value: score, lineWidth: 7)
                        Image(systemName: "brain.head.profile").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.violet)
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        (Text("\(Int((score * 100).rounded()))").font(Typo.number(34, .heavy)).foregroundStyle(Palette.ink)
                            + Text("%").font(Typo.number(18, .bold)).foregroundStyle(Palette.textSoft))
                        Text("\(model.learned.filter(\.learnedFromUser).count + model.facts.count) things learned from you")
                            .font(Typo.small).foregroundStyle(Palette.textSoft)
                    }
                }
            }
        }
    }

    private var scheduleWidget: some View {
        @Bindable var model = model
        return Card(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                widgetHeader("Daily run") {
                    Toggle("", isOn: $model.settings.schedule.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                if model.settings.schedule.enabled {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timeText).font(Typo.number(30, .heavy)).foregroundStyle(Palette.ink)
                        Text(model.settings.schedule.weekdaysOnly ? "weekdays" : "every day").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textSoft)
                    }
                    Text("The app opens by itself, applies in \(model.settings.practiceMode ? "practice mode" : "earnest"), then quits. Your Mac needs to be on.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Let it look for new jobs every morning, without you opening it.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                }
                MoreLink(title: "Change time") { model.page = .settings }
            }
        }
        .onChange(of: model.settings.schedule) { model.applySchedule() }
    }

    private var timeText: String {
        let s = model.settings.schedule
        return String(format: "%d:%02d", s.hour % 12 == 0 ? 12 : s.hour % 12, s.minute) + (s.hour < 12 ? " am" : " pm")
    }

    /// What a run depends on, as rows with the state on the right (like Naver's market list).
    private var connectionsWidget: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 0) {
                widgetHeader("Connections") { MoreLink(title: "Settings") { model.page = .settings } }.padding(.bottom, 6)
                connection("LinkedIn", model.linkedInState == .signedIn ? "Signed in" : "Not signed in", model.linkedInState == .signedIn ? .green : .amber)
                connection("AI helper", aiLine.text, aiLine.tone)
                connection("Email codes", model.secrets.emailConfigured ? "On" : "Off", model.secrets.emailConfigured ? .green : .neutral)
                connection("Browser", model.usesCloud ? "Cloud" : "This Mac", .neutral, last: true)
            }
        }
    }

    private var aiLine: (text: String, tone: Tone) {
        switch model.aiState {
        case .ready(let name): (name, .green)
        case .checking: ("Checking…", .neutral)
        case .working: ("Setting up…", .blue)
        case .needsSetup: ("Not set up", .amber)
        case .failed: ("Not working", .red)
        }
    }

    private func connection(_ title: String, _ value: String, _ tone: Tone, last: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            if tone != .neutral { Circle().fill(tone.color).frame(width: 6, height: 6) }
            Text(value).font(.system(size: 13, weight: .bold)).foregroundStyle(tone == .neutral ? Palette.textSoft : tone.color).lineLimit(1)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Palette.line).frame(height: 1) } }
    }

    private func widgetHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(Typo.heading(15)).foregroundStyle(Palette.ink)
            Spacer()
            trailing()
        }
    }

    // MARK: stats

    private var stats: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("This week").font(Typo.heading(16)).foregroundStyle(Palette.ink)
                    Spacer()
                    MoreLink(title: "All applications") { model.page = .applications }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                HStack(spacing: 0) {
                    StatTile(value: "\(model.weekCounts[.applied] ?? 0)", label: "Sent", symbol: "paperplane.fill", tone: .green)
                    divider
                    StatTile(value: "\(model.weekCounts[.practiceComplete] ?? 0)", label: "Practice, ready", symbol: "checkmark.seal.fill", tone: .blue)
                    divider
                    Button { model.page = .inbox } label: {
                        StatTile(value: "\(model.pending.count)", label: "Questions for you", symbol: "questionmark.bubble.fill", tone: .amber)
                    }
                    .buttonStyle(.plain)
                    divider
                    Button { model.page = .knowledge } label: {
                        StatTile(value: "\(model.learned.filter(\.learnedFromUser).count + model.facts.count)", label: "Learned from you",
                                 symbol: "brain.head.profile", tone: .violet)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.line).frame(width: 1, height: 40).padding(.horizontal, 16)
    }

    // MARK: activity

    private var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Last two weeks").font(Typo.heading(16)).foregroundStyle(Palette.ink)
                    Spacer()
                    legend(Palette.green, "Sent")
                    legend(Palette.blue, "Practice")
                }
                let empty = model.activity.allSatisfy { $0.sent + $0.prepared == 0 }
                Chart(model.activity) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Sent", day.sent))
                        .foregroundStyle(Palette.green)
                        .cornerRadius(2)
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Practice", day.prepared))
                        .foregroundStyle(Palette.blue.opacity(0.8))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textFaint)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Palette.line)
                        AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.textFaint)
                    }
                }
                .chartYScale(domain: 0...max(4, (model.activity.map { $0.sent + $0.prepared }.max() ?? 0) + 1))
                .frame(height: 150)
                .overlay {
                    if empty {
                        Text("Your applications will show up here after the first run.")
                            .font(Typo.small).foregroundStyle(Palette.textSoft)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Palette.sunken, in: Capsule())
                    }
                }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.textSoft)
        }
    }

    // MARK: suggestions and runs

    private var suggestions: some View {
        let items = Array(model.knowledge.suggestions.prefix(3))
        return Group {
            if !items.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Make it smarter").font(Typo.heading(16)).foregroundStyle(Palette.ink)
                            Spacer()
                            MoreLink(title: "What it knows") { model.page = .knowledge }
                        }
                        Text("The more it knows, the fewer questions it has to leave for you.")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.textSoft)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                Text("#").font(.system(size: 15, weight: .heavy)).foregroundStyle(Palette.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(Typo.bodyStrong).foregroundStyle(Palette.ink)
                                    Text(item.detail).font(Typo.small).foregroundStyle(Palette.textSoft)
                                }
                                Spacer()
                                Button("Add") { model.go(to: item.destination) }.buttonStyle(SecondaryButtonStyle())
                            }
                            .padding(.vertical, 2)
                            if item.id != items.last?.id { Divider().overlay(Palette.line) }
                        }
                    }
                }
            }
        }
    }

    private var recentRuns: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent runs").font(Typo.heading(16)).foregroundStyle(Palette.ink).padding(.bottom, 8)
                ForEach(model.runs.prefix(5)) { run in
                    HStack(spacing: 12) {
                        Pill(text: run.practice ? "Practice" : "Real", tone: run.practice ? .blue : .green)
                        Text(run.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            .font(Typo.body).foregroundStyle(Palette.textSoft)
                        Spacer()
                        Text(runLine(run)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    }
                    .padding(.vertical, 9)
                    .hairline(.top)
                }
            }
        }
    }

    private func runLine(_ r: RunRecord) -> String {
        if r.finishedAt == nil { return "Didn't finish" }
        var parts = [r.practice ? "\(r.prepared) ready" : "\(r.sent) sent"]
        if r.needsAnswer > 0 { parts.append("\(r.needsAnswer) need you") }
        if r.failed > 0 { parts.append("\(r.failed) didn't finish") }
        return parts.joined(separator: " · ")
    }
}

extension AppModel {
    func go(to destination: KnowledgeReport.Item.Destination) {
        switch destination {
        case .profile: profileSection = .about; page = .profile
        case .experience: profileSection = .experience; page = .profile
        case .workPay: profileSection = .workPay; page = .profile
        case .jobs: page = .search
        case .memory: page = .knowledge
        case .inbox: page = .inbox
        case .connections: page = .settings
        }
    }
}

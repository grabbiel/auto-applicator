import AppKit
import Engine
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.settings.setupComplete {
                MainView().transition(.opacity)
            } else {
                OnboardingView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.settings.setupComplete)
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .sheet(isPresented: $model.showSignIn) { SignInSheet() }
        .background(WindowAccessor())
        .tint(Palette.green)
    }
}

/// Window touches SwiftUI has no modifier for: drag by the background, a page-colored backdrop.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x131313) : .white }
            window.identifier = NSUserInterfaceItemIdentifier("main")
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The layout of naver.com: the search box on top, a row of service shortcuts under it, then the page.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TopBar().zIndex(2)
            ShortcutBar()
                .padding(.bottom, 12)
                .hairline()
                .zIndex(1)
            content
                .id(model.page)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.22), value: model.page)
        }
        .background(Palette.canvas)
        .tourOverlay()
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .home: HomeView()
        case .live: LiveView()
        case .inbox: InboxView()
        case .applications: ApplicationsView()
        case .knowledge: KnowledgeView()
        case .profile: ProfileView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - top bar

/// The green search box in the middle, the run status and the questions bell on the right.
private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            SearchBox().frame(maxWidth: 620).padding(.horizontal, 190)
            HStack(spacing: 10) {
                Spacer()
                statusChip
                bell
            }
            .padding(.trailing, 22)
        }
        .frame(height: 70)
        .padding(.top, 4)
    }

    private var statusChip: some View {
        Button { model.page = model.isRunning ? .live : .home } label: {
            HStack(spacing: 7) {
                if model.isRunning {
                    PulsingDot(color: Palette.red)
                    Text(model.runPractice ? "Practice run" : "Applying").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("\(model.outcomes.count) done").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.textSoft)
                } else {
                    Circle().fill(model.settings.practiceMode ? Palette.blue : Palette.green).frame(width: 7, height: 7)
                    Text(model.settings.practiceMode ? "Practice mode" : "Sending for real").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.text)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.lineStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.isRunning ? "Watch the run" : scheduleLine)
    }

    private var bell: some View {
        Button { model.page = .inbox } label: {
            Hover { hovering in
                Image(systemName: "bell")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Palette.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(hovering ? Palette.sunken : .clear))
                    .overlay(alignment: .topTrailing) {
                        if !model.pending.isEmpty {
                            Text("\(model.pending.count)")
                                .font(.system(size: 9.5, weight: .heavy).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4.5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Palette.red, in: Capsule())
                                .offset(x: 2, y: 1)
                        }
                    }
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help(model.pending.isEmpty ? "No questions waiting" : "\(model.pending.count) question\(model.pending.count == 1 ? "" : "s") waiting for you")
    }

    private var scheduleLine: String {
        guard let next = model.nextScheduledRun else { return "No daily schedule" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return "Next run " + f.string(from: next).replacingOccurrences(of: ",", with: "")
    }
}

// MARK: - search

/// Naver's search box: a pill with a green edge and the brand at its start. It finds jobs, questions, what the app
/// learned, and the place in the app for a setting; the matches drop down under it.
private struct SearchBox: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let hits = model.searchHits(text)
        HStack(spacing: 12) {
            PlaneShape().fill(Palette.green).frame(width: 22, height: 22).padding(.leading, 20)
            TextField("Search jobs, companies, questions, settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .onSubmit { open(highlighted, in: hits) }
                .onChange(of: text) { highlighted = 0 }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, hits.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { text = ""; focused = false; return .handled }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘F").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.textFaint)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
            }
            Button { open(highlighted, in: hits) } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Palette.green, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 5)
        }
        .frame(height: 48)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.green, lineWidth: 2))
        .shadow(color: Palette.green.opacity(focused ? 0.18 : 0), radius: 8, y: 2)
        .animation(.easeOut(duration: 0.15), value: focused)
        .overlay(alignment: .topLeading) {
            if focused && !text.trimmed.isEmpty {
                results(hits)
                    .offset(y: 56)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
    }

    private func results(_ hits: [SearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                Text("Nothing matches “\(text.trimmed)”. Press Return to look in Applications.")
                    .font(Typo.body).foregroundStyle(Palette.textSoft).padding(16)
            } else {
                ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                    if index == 0 || hits[index - 1].section != hit.section {
                        Text(hit.section).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Palette.textFaint)
                            .padding(.horizontal, 18).padding(.top, index == 0 ? 12 : 10).padding(.bottom, 4)
                    }
                    Button { open(index, in: hits) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: hit.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(hit.tone.color)
                                .frame(width: 26, height: 26).background(hit.tone.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                                if !hit.detail.isEmpty {
                                    Text(hit.detail).font(Typo.small).foregroundStyle(Palette.textSoft).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if index == highlighted { Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.textFaint) }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(index == highlighted ? Palette.sunken : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { highlighted = index } }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.edge))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }

    /// Opens a match; with none, looks for the words among the applications.
    private func open(_ index: Int, in hits: [SearchHit]) {
        if hits.indices.contains(index) {
            hits[index].open(model)
        } else if !text.trimmed.isEmpty {
            model.applicationsQuery = text.trimmed
            model.page = .applications
        }
        text = ""
        focused = false
    }
}

struct SearchHit: Identifiable {
    var id: String
    var section: String
    var symbol: String
    var tone: Tone
    var title: String
    var detail: String
    var open: @MainActor (AppModel) -> Void
}

extension AppModel {
    /// What the search box shows for `query`: jobs, waiting questions, what it learned, then places in the app.
    func searchHits(_ query: String) -> [SearchHit] {
        let q = query.trimmed
        guard !q.isEmpty else { return [] }
        let match = { (s: String) in s.localizedCaseInsensitiveContains(q) }
        var hits: [SearchHit] = []

        for job in jobs.filter({ match($0.title) || match($0.company) }).prefix(4) {
            hits.append(SearchHit(id: "job-\(job.id)", section: "Applications", symbol: job.status?.symbol ?? "briefcase",
                                  tone: job.status?.tone ?? .neutral, title: job.title.isEmpty ? job.company : job.title,
                                  detail: [job.company, job.status?.shortLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) { model in
                model.applicationsQuery = match(job.company) ? job.company : job.title
                model.page = .applications
            })
        }
        for question in pending.filter({ match($0.question) || $0.companies.contains(where: match) }).prefix(3) {
            hits.append(SearchHit(id: "q-\(question.hash)", section: "Questions for you", symbol: "questionmark.bubble.fill", tone: .amber,
                                  title: question.question, detail: question.companies.prefix(3).joined(separator: ", ")) { $0.page = .inbox })
        }
        let facts = self.facts.filter { match($0.text) }.prefix(2).map { fact in
            SearchHit(id: "fact-\(fact.id)", section: "What it knows", symbol: "lightbulb.fill", tone: .violet, title: fact.text,
                      detail: "Something you told it") { model in
                model.knowledgeQuery = q
                model.page = .knowledge
            }
        }
        let answers = learned.filter { match($0.question) || match($0.answer) }.prefix(3 - facts.count).map { answer in
            SearchHit(id: "a-\(answer.hash)", section: "What it knows", symbol: "text.bubble.fill", tone: .violet, title: answer.question,
                      detail: answer.answer) { model in
                model.knowledgeQuery = q
                model.page = .knowledge
            }
        }
        hits += facts + answers

        for place in Self.places where place.words.contains(where: { $0.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains($0) }) {
            hits.append(SearchHit(id: "go-\(place.title)", section: "Go to", symbol: place.page.tile.symbol, tone: .neutral,
                                  title: place.title, detail: place.detail) { model in
                if let section = place.section { model.profileSection = section }
                model.page = place.page
            })
            if hits.count >= 12 { break }
        }
        return hits
    }

    private struct Place {
        var title: String
        var detail: String
        var page: AppPage
        var section: ProfileSection? = nil
        var words: [String]
    }

    private static let places: [Place] = [
        Place(title: "Start a run", detail: "Today", page: .home, words: ["start", "run", "apply", "practice", "today", "home"]),
        Place(title: "Watch live", detail: "Live", page: .live, words: ["live", "watch", "stop", "browser"]),
        Place(title: "Questions for you", detail: "Questions", page: .inbox, words: ["question", "answer", "inbox", "skipped"]),
        Place(title: "Applications", detail: "Every job and what happened", page: .applications, words: ["application", "sent", "results", "pdf", "history"]),
        Place(title: "What it knows", detail: "Facts and remembered answers", page: .knowledge, words: ["knowledge", "fact", "memory", "learn", "teach"]),
        Place(title: "Your details", detail: "Profile › About you", page: .profile, section: .about,
              words: ["name", "email", "phone", "address", "city", "website", "profile"]),
        Place(title: "Resume", detail: "Profile", page: .profile, section: .about, words: ["resume", "cv"]),
        Place(title: "Work and pay", detail: "Profile › Work & pay", page: .profile, section: .workPay,
              words: ["salary", "pay", "visa", "sponsorship", "authorization", "relocat", "start date", "gender", "veteran", "disability"]),
        Place(title: "Experience", detail: "Profile › Experience", page: .profile, section: .experience,
              words: ["experience", "skills", "years", "education", "degree"]),
        Place(title: "Job search", detail: "Titles, place, filters", page: .search,
              words: ["search", "title", "keyword", "location", "remote", "hybrid", "level", "avoid", "blacklist"]),
        Place(title: "Daily schedule", detail: "Settings", page: .settings, words: ["schedule", "daily", "time", "automatic"]),
        Place(title: "AI helper", detail: "Settings", page: .settings, words: ["ai", "ollama", "apple intelligence", "model"]),
        Place(title: "LinkedIn sign-in", detail: "Settings", page: .settings, words: ["linkedin", "sign in", "login"]),
        Place(title: "Email codes", detail: "Settings", page: .settings,
              words: ["email code", "imap", "app password", "verification", "gmail", "outlook", "icloud"]),
        Place(title: "Cloud browser", detail: "Settings", page: .settings, words: ["cloud", "aws", "passkey"]),
        Place(title: "Settings", detail: "Everything else", page: .settings, words: ["settings", "preferences", "data", "folder"]),
    ]
}

// MARK: - shortcuts

extension AppPage {
    /// The shortcut tile's icon and color, like Naver's colorful service icons.
    var tile: (symbol: String, color: Color) {
        switch self {
        case .home: ("house.fill", Palette.green)
        case .live: ("play.rectangle.fill", Palette.red)
        case .inbox: ("questionmark.bubble.fill", Palette.amber)
        case .applications: ("tray.full.fill", Palette.blue)
        case .knowledge: ("brain.head.profile", Palette.violet)
        case .profile: ("person.crop.circle.fill", Palette.teal)
        case .search: ("magnifyingglass", Palette.ink)
        case .settings: ("gearshape.fill", Palette.textSoft)
        }
    }
}

/// The page shortcuts under the search box: a white tile with a colored icon and the name under it.
private struct ShortcutBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(AppPage.allCases) { tile($0) }
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(_ page: AppPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            Hover { hovering in
                VStack(spacing: 6) {
                    Image(systemName: page.tile.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(page.tile.color)
                        .frame(width: 46, height: 46)
                        .background {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(selected ? Palette.greenWash : Palette.surface)
                                .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 5 : 3, y: 1)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(selected ? Palette.green : Palette.edge, lineWidth: selected ? 2 : 1)
                        )
                        .overlay(alignment: .topTrailing) { badge(for: page).offset(x: 9, y: -7) }
                        .offset(y: hovering && !selected ? -1 : 0)
                    Text(page.title)
                        .font(.system(size: 12, weight: selected ? .heavy : .semibold))
                        .foregroundStyle(selected ? Palette.ink : Palette.text)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minWidth: 62)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
        }
        .buttonStyle(.plain)
        .tourAnchor("nav.\(page.rawValue)")
    }

    @ViewBuilder private func badge(for page: AppPage) -> some View {
        switch page {
        case .live where model.isRunning:
            Pill(text: "LIVE", tone: .red, solid: true)
        case .inbox where !model.pending.isEmpty:
            Text("\(model.pending.count)")
                .font(.system(size: 10, weight: .heavy).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Palette.red, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.canvas, lineWidth: 1.5))
        case .knowledge:
            Text("\(Int((model.knowledge.score * 100).rounded()))%")
                .font(.system(size: 9.5, weight: .heavy).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minHeight: 17)
                .background(Palette.violet, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.canvas, lineWidth: 1.5))
        default:
            EmptyView()
        }
    }
}

struct PulsingDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(pulse ? 1 : 0.4).opacity(pulse ? 0 : 1)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

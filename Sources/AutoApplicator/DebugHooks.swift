import AppKit
import Engine
import SwiftUI

/// Development aid: `AA_HOME=<temp dir> AA_SNAPSHOTS=<out dir>` renders every screen to PNG and quits, so the UI can be
/// checked without clicking through it. `AA_DEMO=1` first fills the temp folder with sample data. Both refuse to run
/// without AA_HOME, so they never touch a real setup.
@MainActor
enum DebugHooks {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["AA_HOME"]?.isEmpty == false else { return }
        if env["AA_DEMO"] == "1" { seed(model) }
        guard let dir = env["AA_SNAPSHOTS"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let only = env["AA_SNAPSHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        Task {
            if env["AA_DARK"] != "1" { NSApp.appearance = NSAppearance(named: .aqua) }
            try? await Task.sleep(for: .seconds(1.5))
            if let window = mainWindow {
                window.setContentSize(NSSize(width: 1240, height: 820))
                window.center()
            }
            for (name, apply) in shots(model, env: env) where only == nil || only!.contains(name) {
                await apply()
                try? await Task.sleep(for: .milliseconds(1100))
                capture(name, to: out)
            }
            model.isRunning = false  // a demo run would otherwise ask "Stop applying and quit?"
            NSApp.terminate(nil)
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "main" } ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    private static func shots(_ model: AppModel, env: [String: String]) -> [(String, () async -> Void)] {
        var list: [(String, () async -> Void)] = []
        for step in OnboardingStep.allCases {
            list.append(("onboarding-\(step.rawValue)-\(step.railTitle.lowercased().replacingOccurrences(of: " ", with: "-"))", {
                model.settings.setupComplete = false
                model.onboardingStep = step
            }))
        }
        for page in AppPage.allCases {
            list.append(("page-\(page.rawValue)", {
                model.settings.setupComplete = true
                model.tourStep = nil
                model.page = page
            }))
        }
        for section in ProfileSection.allCases.dropFirst() {
            list.append(("profile-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "&", with: "and"))", {
                model.page = .profile
                model.profileSection = section
            }))
        }
        list.append(("search-dropdown", {
            model.page = .home
            try? await Task.sleep(for: .milliseconds(300))
            typeInSearch("customer")
        }))
        list.append(("live-running", {
            typeInSearch(nil)
            model.page = .home
            await demoRun(model, env: env)
            model.page = .live
        }))
        list.append(("home-running", { model.page = .home }))
        list.append(("tour-1", {
            model.isRunning = false
            model.page = .home
            model.tourStep = 0
        }))
        list.append(("tour-3", { model.tourStep = 2 }))
        if model.cloudAvailable {
            list.append(("settings-cloud-signed-out", {
                model.settings.setupComplete = true
                model.tourStep = nil
                model.secrets.cloudRefreshToken = ""
                model.page = .settings
                try? await Task.sleep(for: .milliseconds(400))
                scrollMain(to: 0.42)
            }))
            list.append(("settings-cloud-signed-in", {
                model.secrets.cloudEmail = "jane.doe@example.com"
                model.secrets.cloudRefreshToken = "demo"
                model.settings.cloudBrowser = true
                model.cloudTest = CloudTest(ok: true, message: "Working: Chrome started in 2.4 s and LinkedIn recognized you.",
                                            image: NSImage(named: NSImage.applicationIconName))
                try? await Task.sleep(for: .milliseconds(400))
                scrollMain(to: 0.42)
            }))
        }
        list.append(("dark-home", {
            model.tourStep = nil
            NSApp.appearance = NSAppearance(named: .darkAqua)
            model.page = .home
        }))
        list.append(("dark-inbox", { model.page = .inbox }))
        list.append(("dark-onboarding", {
            model.settings.setupComplete = false
            model.onboardingStep = .about
        }))
        return list
    }

    /// Types into the search box the way a person would (nil clears it and leaves the box).
    private static func typeInSearch(_ text: String?) {
        guard let window = mainWindow, let root = window.contentView else { return }
        func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }
        guard let field = fields(root).first(where: { $0.placeholderString?.hasPrefix("Search jobs") == true }) else { return }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text ?? "", replacementRange: editor.selectedRange())
        if text == nil { window.makeFirstResponder(nil) }
    }

    /// Scrolls the main page to a fraction of its length (for shots of long pages).
    private static func scrollMain(to fraction: CGFloat) {
        guard let root = mainWindow?.contentView else { return }
        func scrollViews(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        guard let scroll = scrollViews(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = scroll.documentView else { return }
        let travel = max(0, doc.frame.height - scroll.contentView.bounds.height)
        let y = doc.isFlipped ? travel * fraction : travel * (1 - fraction)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func capture(_ name: String, to dir: URL) {
        guard let window = mainWindow else { return }
        let file = dir.appendingPathComponent("\(name).png")
        // A real window capture (needs Screen Recording permission); drawing the views ourselves is the fallback.
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
        try? shot.run()
        shot.waitUntilExit()
        if shot.terminationStatus == 0, FileManager.default.fileExists(atPath: file.path) { return }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    // MARK: - sample data

    private static func seed(_ model: AppModel) {
        var p = Profile()
        p.personal.firstName = "Jane"
        p.personal.lastName = "Doe"
        p.personal.email = "jane.doe@example.com"
        p.personal.phone = "(512) 555-0101"
        p.personal.address.city = "Austin"
        p.personal.address.state = "TX"
        p.personal.linkedin = "https://www.linkedin.com/in/janedoe"
        p.compensation.desiredBase = 98000
        p.experienceYears = ["total": 6, "Excel": 6, "Salesforce": 4, "SQL": 2, "Customer success": 5]
        p.skills = ["Excel", "Salesforce", "SQL", "Customer success", "Zendesk", "HubSpot"]
        p.workHistory = [Role(company: "Northwind", title: "Customer Success Manager", location: "Austin, TX", startDate: "2021-03"),
                         Role(company: "Contoso", title: "Account Coordinator", startDate: "2018-06", endDate: "2021-02")]
        p.education = [Education(school: "University of Texas", degree: "BBA", fieldOfStudy: "Marketing", graduationDate: "2018")]
        model.profile = p
        model.settings.search.keywords = ["Customer Success Manager", "Account Manager", "Client Success Lead"]
        model.settings.search.workplace = [.remote, .hybrid]
        if let pdf = try? PDFWriter.letter("Jane Doe\nCustomer Success Manager", title: "Resume") {
            try? FileManager.default.writeSecurely(pdf, to: model.paths.resumeFile)
            model.resumePresent = true
        }
        let db = model.db
        let jobs: [(String, String, String, JobStatus, ATSType?, String)] = [
            ("4011", "Customer Success Manager", "Lattice", .applied, .easyApply, ""),
            ("4012", "Senior Account Manager", "Figma", .practiceComplete, .greenhouse, ""),
            ("4013", "Client Success Lead", "Notion", .needsAnswer, .easyApply, "Waiting for your answer: “Do you have experience with Gainsight?”"),
            ("4014", "Account Manager, Mid-Market", "Ramp", .applied, .lever, ""),
            ("4015", "Customer Success Manager", "Airtable", .failedOTPTimeout, .workday, "The site emailed a code but no inbox is connected."),
            ("4016", "Customer Success Associate", "Canva", .practiceComplete, .easyApply, ""),
            ("4017", "Renewals Manager", "Linear", .applied, .ashby, ""),
        ]
        for j in jobs {
            db.upsertJob(j.0, status: j.3, title: j.1, company: j.2, location: "Remote · United States", ats: j.4,
                         url: "https://www.linkedin.com/jobs/view/\(j.0)/", notes: j.5)
        }
        db.addPending("demo-q1", question: "Do you have experience with Gainsight?", fieldType: "radio", options: ["Yes", "No"], jobID: "4013", company: "Notion")
        db.addPending("demo-q2", question: "How many years of experience do you have with Tableau?", fieldType: "number", options: [], jobID: "4013", company: "Notion")
        db.addPending("demo-q3", question: "What interests you about working at our company?", fieldType: "textarea", options: [], jobID: "4013", company: "Notion")
        db.addFact("I have a valid driver's license")
        db.cachePut("demo-a1", question: "Are you comfortable working across time zones?", fieldType: "radio", options: ["Yes", "No"], answer: "Yes", source: "user")
        db.cachePut("demo-a2", question: "How did you hear about this role?", fieldType: "text", options: [], answer: "LinkedIn", source: "llm:high")
        let run = db.startRun(practice: true)
        db.finishRun(run, sent: 0, prepared: 2, needsAnswer: 1, failed: 0, note: "")
        model.linkedInState = .signedIn
        model.refreshData()
    }

    private static func demoRun(_ model: AppModel, env: [String: String]) async {
        if let page = env["AA_DEMO_PAGE"] {
            try? await model.web.load(URL(fileURLWithPath: page), timeout: 10)
            try? await Task.sleep(for: .milliseconds(400))
            model.livePreview = await model.web.snapshot()
            model.liveURL = "www.linkedin.com"
        }
        model.isRunning = true
        model.runPractice = true
        model.runStartedAt = Date().addingTimeInterval(-252)
        model.runPhase = "Searching “Customer Success Manager”, page 1"
        model.currentJob = JobCard(id: "4018", title: "Customer Success Manager", company: "Webflow", location: "Remote", applied: false)
        model.currentSteps = ["Opened the job posting", "Opened Easy Apply", "Filled 6 fields", "Attached your resume", "Answering 2 questions with the AI"]
        model.outcomes = [
            Outcome(card: JobCard(id: "4016", title: "Customer Success Associate", company: "Canva", location: "Remote", applied: false), ats: .easyApply,
                    result: ApplyResult(.practiceComplete)),
            Outcome(card: JobCard(id: "4013", title: "Client Success Lead", company: "Notion", location: "Remote", applied: false), ats: .easyApply,
                    result: ApplyResult(.needsAnswer, notes: "Waiting for your answer: “Do you have experience with Gainsight?”")),
        ]
    }
}

import AppKit
import XCTest
@testable import Engine

/// Opt-in check of real careers sites: opens each job page in a list, reaches its application and fills it in practice
/// mode with the made-up example profile (Jane Doe, jane.doe@example.com), the on-device AI and the cloud AI, then
/// writes what happened to a JSON line per site. Nothing is ever sent: practice mode stops before the final Submit, no
/// portal password is set (so no account is made or signed in to), email isn't connected (so no code is entered), and a
/// guard stops before any button that would agree to something, make an account, verify or send.
///
///     AA_SURVEY=sites.json AA_SURVEY_OUT=out/ AA_SURVEY_HOME=home/ [AA_SURVEY_SHARD=0/3] [AA_SURVEY_TIMEOUT=300]
///     swift test --filter SiteSurveyTests
///
/// sites.json: [{"id": "…", "url": "…", "company": "…", "title": "…", "location": "…"}]. Sites already in the
/// shard's results file are skipped, so a run can be resumed. The cloud AI is used with the AWS profile in
/// AA_SURVEY_AWS_PROFILE (default "admin") when Resources/CloudConfig.json names one.
@MainActor
final class SiteSurveyTests: XCTestCase {
    struct Site: Codable {
        var id: String
        var url: String
        var company: String
        var title: String
        var location: String?
    }

    func testSurvey() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["AA_SURVEY"], let outDir = env["AA_SURVEY_OUT"], let homeDir = env["AA_SURVEY_HOME"] else {
            throw XCTSkip("Set AA_SURVEY, AA_SURVEY_OUT and AA_SURVEY_HOME to check careers sites.")
        }
        _ = NSApplication.shared
        let shard = (env["AA_SURVEY_SHARD"] ?? "0/1").split(separator: "/").compactMap { Int($0) }
        let (index, count) = shard.count == 2 ? (shard[0], max(1, shard[1])) : (0, 1)
        let timeout = Double(env["AA_SURVEY_TIMEOUT"] ?? "") ?? 300
        let sites = try JSONDecoder().decode([Site].self, from: Data(contentsOf: URL(fileURLWithPath: list)))
            .enumerated().filter { $0.offset % count == index }.map(\.element)

        // The shared home holds the profile and what's learned (answers, the cloud AI's answers); each shard keeps its
        // own log and saved pages.
        let shared = AppPaths(home: URL(fileURLWithPath: homeDir, isDirectory: true)).ensure()
        let mine = AppPaths(home: URL(fileURLWithPath: homeDir).appendingPathComponent("shard-\(index)", isDirectory: true)).ensure()
        // A made-up number in a real area code (555-01xx is kept for fiction): sites that check numbers turn away area code 555.
        var profile = Fixture.profile
        profile.personal.phone = "512-555-0142"
        profile.personal.address.street = "123 Example St"
        for p in [shared, mine] {
            try Store(paths: p).save(profile)
            try PDFWriter.letter(Self.resumeText, title: "Jane Doe – Resume").write(to: p.resumeFile)
        }
        var settings = Settings()
        settings.practiceMode = true
        settings.limits.minDelaySec = 0.5
        settings.limits.maxDelaySec = 1.5
        settings.limits.otpTimeoutSec = 10
        try Store(paths: mine).save(settings)
        let db = try Database(paths: shared)
        Log.configure(mine)
        let logFile = mine.logsDir.appendingPathComponent("app.log")

        let local = AppleIntelligence.makeModel().map { AIService(model: $0) }
        let helper = Self.cloudHelper(env)
        print("SURVEY shard \(index)/\(count): \(sites.count) sites, on-device AI: \(local?.displayName ?? "none"), cloud AI: \(helper?.displayName ?? "none")")

        let out = URL(fileURLWithPath: outDir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let results = out.appendingPathComponent("results-\(index).jsonl")
        let done = Set(((try? String(contentsOf: results, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.compactMap { $0["id"] as? String })

        for site in sites where !done.contains(site.id) {
            guard let url = URL(string: site.url) else { continue }
            let logStart = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? Int) ?? 0
            var record = await run(site, url: url, settings: settings, paths: mine, db: db, profile: profile, ai: local, helper: helper, timeout: timeout)
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let handle = try? FileHandle(forReadingFrom: logFile) {
                try? handle.seek(toOffset: UInt64(logStart))
                let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
                record["log"] = text.split(separator: "\n").suffix(80).map { String($0.prefix(400)) }
                try? handle.close()
            }
            guard JSONSerialization.isValidJSONObject(record) else { XCTFail("record for \(site.id) isn't JSON"); continue }
            let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let handle = try FileHandle(forWritingTo: { if !FileManager.default.fileExists(atPath: results.path) { FileManager.default.createFile(atPath: results.path, contents: nil) }; return results }())
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line + Data("\n".utf8))
            try handle.close()
            print("SURVEY \(record["outcome"] ?? "") | \(site.company) | \(url.host ?? "") | \(String(describing: record["notes"] ?? "").prefix(160))")
        }
    }

    final class Box { var task: Task<ApplyResult?, Error>?; var veto: String?; var timedOut = false }

    private func run(_ site: Site, url: URL, settings: Settings, paths: AppPaths, db: Database, profile: Profile, ai: AIService?, helper: AIService?,
                     timeout: TimeInterval) async -> [String: Any] {
        let web = WebAgent()
        defer { web.close() }
        var steps: [String] = []
        var reachNote: String?
        var ats: ATSType?
        let started = Date()
        let box = Box()
        web.willPress = { [weak web] what, selector in
            guard let web, let reason = await Self.veto(what, selector: selector, web: web) else { return true }
            if reason.isEmpty { return false }  // a cookie banner's Accept: leave the banner
            box.veto = reason
            box.task?.cancel()
            return false
        }
        let job = JobContext(title: site.title, company: site.company, location: site.location ?? "United States", description: "")
        let answerer = Answerer(profile: profile, db: db, ai: ai, helper: helper, batchSize: ai?.batchSize ?? 6)
        let ctx = ApplyContext(jobID: site.id, job: job, settings: settings, paths: paths, profile: profile, db: db, answerer: answerer, ai: ai,
                               verifier: EmailVerifier(secrets: Secrets(), ai: nil), secrets: Secrets(), practice: true, helper: helper) { steps.append($0) }
        box.task = Task { @MainActor in
            try await web.load(url)
            try await web.sleep(3)
            switch try await SiteRouter.reachApplication(web, step: { steps.append($0) }) {
            case .stop(let note):
                reachNote = note
                ats = web.url.map(SiteRouter.detect) ?? .generic
                return nil
            case .ready(let detected):
                ats = detected
                steps.append("Applying through \(detected.label)")
                return try await SiteRouter.handler(detected).init(web: web, ctx: ctx).apply()
            }
        }
        let watchdog = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            box.timedOut = true
            box.task?.cancel()
        }
        var record: [String: Any] = ["id": site.id, "url": site.url, "company": site.company, "title": site.title, "host": url.host ?? ""]
        do {
            let result = try await box.task!.value
            if let result {
                record["outcome"] = result.status.rawValue
                record["notes"] = result.notes
            } else {
                record["outcome"] = "REACH_STOP"
                record["notes"] = reachNote ?? ""
            }
        } catch {
            if let veto = box.veto {
                record["outcome"] = "GUARD_STOP"
                record["notes"] = veto
            } else if box.timedOut {
                record["outcome"] = "TIMEOUT"
                record["notes"] = "Still working after \(Int(timeout)) s"
            } else {
                record["outcome"] = "ERROR"
                record["notes"] = error.localizedDescription
            }
        }
        watchdog.cancel()
        web.willPress = nil
        record["ats"] = ats?.rawValue ?? ""
        record["steps"] = Array(steps.suffix(40))
        record["seconds"] = Int(Date().timeIntervalSince(started))
        record["final_url"] = web.url?.absoluteString ?? ""
        record["page"] = await Self.describePage(web)
        return record
    }

    /// Why the guard won't press this ("" for a cookie banner's Accept, left alone without stopping), or nil to press.
    static func veto(_ what: String, selector: String, web: WebAgent) async -> String? {
        let parts = what.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        let kind = parts.first?.lowercased() ?? "", name = (parts.count > 1 ? parts[1] : "").lowercased()
        if selector.contains("data-auto-banner") {
            return Regex(#"reject|decline|necessary|essential|required only|close|dismiss|no,? thanks|without accepting|^x$|^×$|deny|refuse|opt out|save (my )?(choices|preferences|settings)|^$"#).matches(name) ? nil : ""
        }
        // Answering a question (a box, a choice, an option in a list) is fine; the page isn't sent by it.
        if Regex(#"checkbox|radio|option|combobox|listbox|textbox|select|text|email|tel|number|date|search|file|li\b|span\b|label\b|td\b"#).matches(kind)
            && !Regex(#"\b(submit|button)\b"#).matches(kind) {
            return nil
        }
        if Regex(#"\b(i )?(agree|accept|acknowledge|consent|certify|attest)\b|e-?sign|\bsign\b(?! ?in)"#).matches(name) { return "Would agree to something: “\(name)”" }
        // A choice in a popup that says choosing it agrees to something (Workday's "By selecting an option below, I hereby
        // consent to the cross-border transfer of my personal data").
        if await web.bool(#"""
            const el = document.querySelector(sel), d = el && el.closest('[role=dialog], [role=alertdialog], dialog, [aria-modal=true]');
            return !!d && /\b(by (selecting|clicking|choosing|pressing)\b.{0,80}\b(i|you) (hereby )?(agree|consent|acknowledge|accept)|i hereby (agree|consent))/i.test((d.innerText || '').slice(0, 2000));
            """#, ["sel": selector]) {
            return "Would agree to what the popup says by choosing “\(name)”"
        }
        if Regex(#"create( an| a| my| your)? (account|profile|login)|\bregister\b|sign ?up|\bjoin\b|talent (community|network)|subscribe"#).matches(name) {
            return "Would make an account: “\(name)”"
        }
        if Regex(#"\b(sign|log) ?in\b|\blogin\b"#).matches(name) { return "Would sign in: “\(name)”" }
        // A way into the form named "Submit" (BrassRing's job page) sends nothing; "Review and submit" opens a review page.
        let entry = selector.contains("data-auto-entry") && Regex(#"^(submit|apply\b.*)$"#).matches(name)
        if !entry, !Regex(#"^review (and|&) submit$"#).matches(name),
           Regex(#"\b(verify|send|submit|finish|complete|confirm)\b|\bget (a |the )?code\b"#).matches(name) {
            return "Would send or verify: “\(name)”"
        }
        // Moving on with a ticked "I agree" / privacy box on the page would agree to it.
        if Regex(#"^(next|continue|save|proceed|review|ok|okay|done)\b"#).matches(name), await consentTicked(web) {
            return "Would move on with an “I agree” box ticked (“\(name)”)"
        }
        return nil
    }

    static func consentTicked(_ web: WebAgent) async -> Bool {
        await web.bool(#"""
            const re = /\b(i (have read|agree|consent|acknowledge|accept|certify|attest|understand)|agree to|consent to|terms (of|and)|privacy (policy|notice|statement)|acknowledg)/i;
            return [...document.querySelectorAll('input[type=checkbox]:checked, input[type=radio]:checked, [role=checkbox][aria-checked=true]')].some(el => {
                const text = ((el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('aria-label') || (el.closest('label, [class*=field i], [class*=question i], fieldset, div') || el).innerText || '');
                return re.test(text.slice(0, 600));
            });
            """#)
    }

    static func describePage(_ web: WebAgent) async -> [String: Any] {
        let fields = await web.extractFields(root: nil, exclude: ApplicationHandler.exclude)
        let buttons = ((try? await web.js(#"""
            return [...document.querySelectorAll('button, [role=button], input[type=submit], input[type=button], a.btn, a[class*=button i]')]
                .filter(b => b.offsetWidth > 0 && b.offsetHeight > 0).map(b => (b.innerText || b.value || b.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim())
                .filter(t => t).slice(0, 30);
            """#)) as? [String]) ?? []
        return [
            "fields": fields.prefix(60).map { "\($0.kind)\($0.spec.required ? "*" : "") \($0.spec.label.prefix(90)) = \($0.spec.currentValue.prefix(50))" },
            "errors": Array((await web.collectErrors()).values.prefix(10)),
            "buttons": buttons,
            "text": String(await web.text(maxChars: 900).prefix(900)),
        ]
    }

    /// The cloud AI with credentials from the AWS CLI profile (refreshed as they expire).
    static func cloudHelper(_ env: [String: String]) -> AIService? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard env["AA_SURVEY_NO_CLOUD"] != "1",
              let data = try? Data(contentsOf: repo.appendingPathComponent("Resources/CloudConfig.json")),
              let config = try? JSONDecoder().decode(CloudConfig.self, from: data) else { return nil }
        let profile = env["AA_SURVEY_AWS_PROFILE"] ?? "admin"
        let cache = CredentialCache()
        guard let model = CloudModel(config: config, credentials: { try await cache.get(profile) }) else { return nil }
        return AIService(model: model)
    }

    actor CredentialCache {
        var creds: AWSCredentials?
        func get(_ profile: String) throws -> AWSCredentials {
            if let creds, creds.expiration.timeIntervalSinceNow > 300 { return creds }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["aws", "configure", "export-credentials", "--profile", profile, "--format", "process"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let key = j["AccessKeyId"] as? String,
                  let secret = j["SecretAccessKey"] as? String else { throw BrowserError("No AWS credentials for the profile \(profile).") }
            let expiry = (j["Expiration"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date().addingTimeInterval(3000)
            let fresh = AWSCredentials(accessKeyId: key, secretAccessKey: secret, sessionToken: j["SessionToken"] as? String, expiration: expiry)
            creds = fresh
            return fresh
        }
    }

    static let resumeText = """
        Jane Doe
        Austin, TX · jane.doe@example.com · 512-555-0142 · linkedin.com/in/janedoe · github.com/janedoe

        SUMMARY
        Backend engineer with 6 years building data-intensive Python services and APIs.

        EXPERIENCE
        Senior Software Engineer, Acme Corp, Austin, TX (March 2022 – Present)
        • Led migration of billing services to Kubernetes, cutting infra cost 30%.

        Software Engineer, Globex, Remote (June 2019 – February 2022)
        • Built FastAPI services handling 2k req/s.

        EDUCATION
        University of Texas at Austin — Bachelor of Science, Computer Science (2015 – 2019)

        SKILLS
        Python, SQL, PostgreSQL, AWS, Docker, Kubernetes, FastAPI
        """
}

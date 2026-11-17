import Foundation

/// What the cloud AI said to do on a page where the form got stuck.
struct UIStep: Sendable {
    enum Action: String, Sendable { case press, submit, fill, stop }
    var action: Action
    var element: Int?
    var fixes: [(field: Int, value: String)]
    var reason: String
}

extension AIService {
    static let unstickInstructions = """
    You help an app that fills in a job application in a web browser when it gets stuck. You see the page's fields and \
    buttons, numbered, and what went wrong. Choose ONE action:
    - press: press the button or link [element] to move the application forward (Next, Continue, Apply, Start the \
    application, or close a popup that is in the way).
    - submit: [element] is the button that sends the finished application. The app decides itself whether to press it.
    - fill: fix the fields the errors are about. Each fix gives the field number and the value; for a field with options, \
    one of its options copied exactly. Use only the candidate's details.
    - stop: nothing on the page moves the application forward (the job is closed, the site wants a sign-in through \
    another company's account, a puzzle to prove you're human). Say why in reason. Whether the job suits the candidate \
    is not yours to judge: they chose to apply, so never stop for that.
    Never choose a button that signs in with another company's account (Google, LinkedIn, Apple, Microsoft, Facebook, \
    GitHub, Indeed), logs out, only saves a draft, changes cookie settings, opens another job, or leaves the application \
    (Home, the site's logo, About, the job list). Only use numbers listed.
    reason: one short sentence.
    """

    /// Asks which control moves a stuck application on.
    func unstick(page: String) async throws -> UIStep {
        let schema = AISchema.object([
            ("reason", .string),
            ("action", .choice(UIStep.Action.allValues)),
            ("element", .number),
            ("fixes", .array(.object([("field", .number), ("value", .string)]), max: 8)),
        ])
        let json = try await model.generate(instructions: Self.unstickInstructions, prompt: String(page.prefix(model.promptBudget)), schema: schema)
        guard let action = UIStep.Action(rawValue: Self.string(json["action"]).lowercased()) else {
            throw AIError.badOutput("no action")
        }
        let fixes = ((json["fixes"] as? [[String: Any]]) ?? []).compactMap { f -> (Int, String)? in
            guard let n = (f["field"] as? NSNumber)?.intValue else { return nil }
            return (n, Self.string(f["value"]))
        }
        return UIStep(action: action, element: (json["element"] as? NSNumber)?.intValue, fixes: fixes, reason: Self.string(json["reason"]))
    }
}

extension UIStep.Action {
    static let allValues = ["press", "submit", "fill", "stop"]
}

extension ApplicationHandler {
    enum Rescue {
        /// Something was pressed or filled: look at the page again.
        case moved
        /// This button (tagged for `clickFoundButton`) sends the application.
        case submit(String)
        case stop(String)
    }

    /// Buttons that sign in with another company's account: never pressed.
    static let otherAccountButton = Regex(#"\b(sign ?in|log ?in|continue|apply|connect)\s+(with|using|via|through)\s+(linkedin|google|github|apple|microsoft|facebook|indeed|seek|x|twitter)\b|^(linkedin|google|apple|indeed)$"#)

    /// When the form gets stuck (no button the app knows, a page that doesn't move on, errors it can't fix, no form
    /// where one should be): first what moved this site's form on before, else the cloud AI, shown the page's fields
    /// and buttons. What works is remembered for the site. Nil when there's no cloud AI or it has nothing to offer.
    func rescue(_ problem: String, root: String?) async throws -> Rescue? {
        guard let helper = ctx.helper, rescuesLeft > 0 else { return nil }
        rescuesLeft -= 1
        let host = web.url?.host?.lowercased() ?? ""
        let buttons = await uiButtons(root: root)
        let fields = await web.extractFields(root: root, exclude: Self.exclude).filter { $0.kind != .file }
        // Without boxes to send, "Apply" is the way into the form, not the end of it (ADP's job page).
        let isFinal = { (name: String) in !fields.isEmpty && finalButtonWords.matches(norm(name)) }
        // A button that moved this site's form on before.
        if let learned = ctx.db.meta("ui-press:\(host)"), let i = buttons.firstIndex(where: { $0.caseInsensitiveCompare(learned) == .orderedSame }),
           !triedLearned.contains(learned) {
            triedLearned.insert(learned)
            let name = Self.bare(learned)
            ctx.step("Pressing “\(name)”, which moved \(siteName)'s form on before")
            Log.info("Rescue on \(host): pressing the remembered “\(name)”")
            if isFinal(name) { return await tagForSubmit(i, name) }
            await web.click(#"[data-auto-ui="\#(i)"]"#)
            try await web.sleep(2)
            return .moved
        }
        var page = "CANDIDATE:\n\(ctx.answerer.cloudProfileText.prefix(3500))\n\n"
        page += "JOB: \(ctx.job.title) at \(ctx.company)\n"
        page += "PAGE: \(web.url.map { "\($0.host ?? "")\($0.path)" } ?? "")\n"
        page += "PROBLEM: \(problem)\n\n"
        page += "TEXT:\n\(await web.text(maxChars: 1500))\n\n"
        page += "FIELDS:\n" + fields.prefix(40).enumerated().map { i, f in
            let options = f.spec.options.isEmpty ? "" : " options: " + f.spec.options.prefix(15).joined(separator: " | ")
            let error = f.spec.error.isEmpty ? "" : " ERROR: \(f.spec.error)"
            return "[\(i)] \(f.spec.label.prefix(120)) (\(f.spec.type.rawValue)\(f.spec.required ? ", required" : "")) = \"\(f.spec.currentValue.prefix(60))\"\(options)\(error)"
        }.joined(separator: "\n")
        page += "\n\nBUTTONS:\n" + buttons.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
        ctx.step("Asking the cloud AI what to do: \(problem.prefix(100))")
        let step: UIStep
        do {
            step = try await helper.unstick(page: page)
        } catch {
            Log.warn("The cloud AI couldn't help on \(host): \(error.localizedDescription)")
            return nil
        }
        Log.info("Cloud AI on \(host) (\(problem.prefix(80))): \(step.action.rawValue) \(step.element.map(String.init) ?? "") \(step.fixes.map { "\($0.field)=\($0.value.prefix(30))" }) – \(step.reason)")
        switch step.action {
        case .stop:
            return .stop(step.reason)
        case .press, .submit:
            guard let i = step.element, buttons.indices.contains(i) else { return nil }
            let name = Self.bare(buttons[i])
            if Self.otherAccountButton.matches(norm(name)) { return .stop("It would mean signing in with another account (“\(name)”).") }
            // A sign-up beside the job (New York Life's "Join Talent Network") is never the way into the application.
            if Self.signUpButton.matches(norm(name)) {
                return .stop("The page offers only a sign-up (“\(name)”), not the application.")
            }
            if (step.action == .submit && !fields.isEmpty) || isFinal(name) { return await tagForSubmit(i, name) }
            ctx.step("Pressing “\(name)” (the cloud AI: \(step.reason.prefix(100)))")
            let before = "\(web.url?.absoluteString ?? "")|\(await web.text(maxChars: 1500))"
            await web.click(#"[data-auto-ui="\#(i)"]"#)
            lastActionAt = Date()
            try await web.sleep(2.5)
            if before != "\(web.url?.absoluteString ?? "")|\(await web.text(maxChars: 1500))", !host.isEmpty {
                ctx.db.setMeta("ui-press:\(host)", buttons[i])
            }
            return .moved
        case .fill:
            var filled = 0
            for fix in step.fixes where fields.indices.contains(fix.field) && !fix.value.isEmpty {
                let f = fields[fix.field]
                // Who the person is stays theirs to say, whatever the form wants (see `Answerer.selfIdentification`).
                if Answerer.selfIdentification(f.spec) { continue }
                var value = fix.value
                if !f.spec.options.isEmpty {
                    guard let match = f.spec.options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
                        ?? f.spec.options.first(where: { norm($0) == norm(value) }) else { continue }
                    value = match
                }
                if await web.fill(f, value) { filled += 1 }
            }
            guard filled > 0 else { return nil }
            ctx.step("Changed \(filled) answer\(filled == 1 ? "" : "s") the cloud AI pointed out (\(step.reason.prefix(100)))")
            return .moved
        }
    }

    static let signUpButton = Regex(#"talent (community|network|pool)|job alerts?|\bsubscribe\b|newsletter|^join\b|\bjoin (our|the|us)\b|sign ?up for"#)

    /// Tags the button for `clickFoundButton` (the app's own Submit step presses it, or practice mode stops there).
    private func tagForSubmit(_ i: Int, _ name: String) async -> Rescue {
        await web.bool(#"""
            document.querySelectorAll('[data-auto-btn]').forEach(e => e.removeAttribute('data-auto-btn'));
            const el = document.querySelector('[data-auto-ui="' + i + '"]'); if (el) el.setAttribute('data-auto-btn', '1'); return !!el;
            """#, ["i": i])
        return .submit(name)
    }

    /// "Next (button)" → "Next"; "Apply (button 2)" → "Apply".
    static func bare(_ listed: String) -> String {
        listed.replacingOccurrences(of: #" \((button|link)( \d+)?\)$"#, with: "", options: .regularExpression)
    }

    /// The page's visible buttons and links, numbered (tagged data-auto-ui) for the cloud AI.
    func uiButtons(root: String?) async -> [String] {
        var args: [String: Any] = ["rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        return ((try? await web.js(Scripts.prelude + #"""
            document.querySelectorAll('[data-auto-ui]').forEach(e => e.removeAttribute('data-auto-ui'));
            const scope = (rootSel && document.querySelector(rootSel)) || document;
            const seen = new Map(), out = [];
            for (const el of scope.querySelectorAll('button, [role=button], input[type=submit], input[type=button], a[href], [role=link], [onclick]')) {
                if (out.length >= 45 || !shown(el) || el.disabled || el.getAttribute('aria-disabled') === 'true') continue;
                if (el.closest('#onetrust-consent-sdk, [id*=cookie i]:not(body):not(html), [class*=cookie i]:not(body):not(html)')) continue;
                const name = (words(el) || el.getAttribute('aria-label') || el.title || '').replace(/\s+/g, ' ').trim().slice(0, 70);
                if (!name || name.length < 2) continue;
                const kind = el.tagName === 'A' || el.getAttribute('role') === 'link' ? 'link' : 'button';
                // The same name twice is listed twice (ADP's job page has two "Apply" buttons; only the second works).
                const key = kind + ':' + name.toLowerCase();
                const n = (seen.get(key) || 0) + 1;
                if (n > 3) continue;
                seen.set(key, n);
                el.setAttribute('data-auto-ui', String(out.length));
                out.push(name + ' (' + kind + (n > 1 ? ' ' + n : '') + ')');
            }
            return out;
            """#, args)) as? [String]) ?? []
    }
}

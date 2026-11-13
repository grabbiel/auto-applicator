import Engine
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, resume, about, workPay, experience, search, ai, linkedin, email, ready
    var id: Int { rawValue }

    var railTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .resume: "Your resume"
        case .about: "About you"
        case .workPay: "Work & pay"
        case .experience: "Experience"
        case .search: "Jobs to find"
        case .ai: "AI helper"
        case .linkedin: "LinkedIn"
        case .email: "Email codes"
        case .ready: "All set"
        }
    }

    var title: String {
        switch self {
        case .welcome: ""
        case .resume: "Start with your resume"
        case .about: "Check your details"
        case .workPay: "Work and pay"
        case .experience: "Your experience"
        case .search: "What jobs should it find?"
        case .ai: "Your AI helper"
        case .linkedin: "Connect LinkedIn"
        case .email: "Email codes"
        case .ready: "You're all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: ""
        case .resume: "It reads your resume and fills in most of the next steps for you. It's also attached to every application."
        case .about: "This is what employers see. Fix anything that's wrong or missing."
        case .workPay: "Questions almost every application asks. Answer once here."
        case .experience: "Forms keep asking “How many years of…?”. These numbers answer for you."
        case .search: "It searches LinkedIn for these titles and applies to the ones that fit."
        case .ai: "For open questions like “Why do you want this job?” and for cover letters."
        case .linkedin: "It finds and applies to jobs through your own LinkedIn account."
        case .email: "Optional. Lets it finish company sites that email you a code."
        case .ready: "Here's how to get the most out of it."
        }
    }

    var optional: Bool { [.resume, .ai, .linkedin, .email].contains(self) }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            OnboardingRail().frame(width: 290)
            ZStack {
                Palette.canvas
                if model.onboardingStep == .welcome {
                    WelcomeStep().transition(.opacity)
                } else {
                    StepFrame(step: model.onboardingStep).id(model.onboardingStep).transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: model.onboardingStep)
        }
        .background(Palette.canvas)
    }
}

// MARK: - rail

/// The steps down the left side on light grey, the current one in heavy black with a green ring.
private struct OnboardingRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 28)
                Wordmark(size: 17)
            }
            .padding(.top, 50)
            .padding(.bottom, 34)

            Text("Let's get you set up").font(Typo.display(22)).foregroundStyle(Palette.ink)
            Text("About five minutes. You can change anything later.").font(.system(size: 12.5)).foregroundStyle(Palette.textSoft)
                .padding(.top, 6)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(OnboardingStep.allCases) { step in
                    row(step)
                }
            }
            Spacer()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Palette.green).font(.system(size: 13))
                Text("Everything you enter stays on this Mac. Nothing is uploaded except the applications you send.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 26)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sunken)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
    }

    private func row(_ step: OnboardingStep) -> some View {
        let current = model.onboardingStep
        let done = step.rawValue < current.rawValue
        let active = step == current
        return Button {
            if done { model.onboardingStep = step }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if done {
                        Circle().fill(Palette.green)
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                    } else if active {
                        Circle().fill(Palette.surface)
                        Circle().strokeBorder(Palette.green, lineWidth: 2)
                        Circle().fill(Palette.green).frame(width: 7, height: 7)
                    } else {
                        Circle().fill(Palette.surface)
                        Circle().strokeBorder(Palette.lineStrong, lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
                Text(step.railTitle)
                    .font(.system(size: 13, weight: active ? .heavy : done ? .semibold : .medium))
                    .foregroundStyle(active ? Palette.ink : done ? Palette.text : Palette.textFaint)
                Spacer()
            }
            .frame(height: 34)
            .overlay(alignment: .topLeading) {
                if step != OnboardingStep.allCases.last {
                    Rectangle().fill(done ? Palette.green : Palette.lineStrong).frame(width: 1.5, height: 16).offset(x: 8.25, y: 26)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(done)  // (not .disabled: that would dim the current step)
    }
}

// MARK: - welcome

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 30)
            BrandMark(size: 64).shadow(color: Palette.green.opacity(0.3), radius: 16, y: 6)
            (Text("Your job search,\n").foregroundStyle(Palette.ink) + Text("on autopilot.").foregroundStyle(Palette.green))
                .font(Typo.display(44))
                .lineSpacing(2)
                .padding(.top, 26)
            Text("Auto Applicator finds jobs on LinkedIn that match what you want, fills in the applications for you, and gets smarter with every answer you give it.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.textSoft)
                .lineSpacing(3)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 26)

            VStack(alignment: .leading, spacing: 18) {
                how(1, "Tell it about yourself", "Start with your resume. It reads it and fills in the details for you.")
                how(2, "It applies while you do other things", "It searches LinkedIn and fills each form the way a person would.")
                how(3, "You only answer what it can't", "Answer a question once and it remembers it for every application after.")
            }
            .padding(.top, 34)

            HStack(spacing: 16) {
                Button { model.onboardingStep = .resume } label: {
                    HStack(spacing: 8) { Text("Start setup"); Image(systemName: "arrow.right") }
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                Text("Takes about 5 minutes").font(Typo.small).foregroundStyle(Palette.textFaint)
            }
            .padding(.top, 38)
            Spacer(minLength: 30)
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func how(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Palette.green, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                Text(detail).font(Typo.body).foregroundStyle(Palette.textSoft)
            }
        }
    }
}

// MARK: - steps

private struct StepFrame: View {
    @Environment(AppModel.self) private var model
    var step: OnboardingStep

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("Step \(step.rawValue) of \(OnboardingStep.allCases.count - 1)", color: Palette.greenDeep)
                        Text(step.title).font(Typo.display(28)).foregroundStyle(Palette.ink)
                        Text(step.subtitle).font(.system(size: 14)).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)
                    content
                }
                .padding(.horizontal, 48)
                .padding(.top, 46)
                .padding(.bottom, 30)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            footer
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: EmptyView()
        case .resume:
            ResumeDropZone()
            CoachTip(title: "No PDF?", text: "In **Word** or **Pages**, choose File › Export To › PDF. In **Google Docs**, choose File › Download › PDF. Then drop that file above.")
        case .about:
            if model.resumePresent && model.profile.isComplete {
                CoachTip(text: "These came from your resume. Give them a quick check: this is exactly what employers will see.", symbol: "sparkles")
            }
            AboutYouForm(compact: true)
        case .workPay:
            WorkPayForm(compact: true)
            CoachTip(title: "Not sure what salary to put?",
                     text: "Search the job title on LinkedIn or Glassdoor and pick the middle of the range for your city. You can change it any time.")
        case .experience:
            ExperienceForm(compact: true)
            CoachTip(text: "Round to whole years and count only real, hands-on experience. When in doubt, the lower number is the safer answer.")
        case .search:
            SearchForm(compact: true)
            CoachTip(title: "Pick 2 to 4 titles",
                     text: "Use the words employers put in job titles, like “Customer Success Manager” rather than “helping customers”. You can add more later.")
        case .ai:
            Card { AIStatusView(showEngineChoice: false) }
            CoachTip(text: "The AI only fills in answers using what you've told it. It never makes up jobs or degrees, and anything it isn't sure about is left for you to answer.",
                     symbol: "checkmark.shield")
        case .linkedin:
            Card { LinkedInStatusView() }
            CoachTip(title: "What happens when you press Sign in",
                     text: "LinkedIn's normal sign-in page opens in a window here. Type your email and password there, just like in a browser. The window closes by itself once you're in.")
        case .email:
            Card { EmailSetupView() }
            CoachTip(text: "You can skip this. Jobs that need an emailed code will simply wait in Applications for you to finish.",
                     symbol: "arrow.uturn.forward")
        case .ready:
            ReadyStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.onboardingStep = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
            } label: {
                HStack(spacing: 6) { Image(systemName: "arrow.left"); Text("Back") }
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer()
            if let missing = missing {
                Text(missing).font(Typo.small).foregroundStyle(Palette.textFaint)
            }
            if step == .ready {
                Button("Go to my dashboard") { model.finishOnboarding() }.buttonStyle(PrimaryButtonStyle(large: true))
            } else {
                let next = {
                    model.saveNow()
                    model.onboardingStep = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                }
                if continueTitle == "Continue" {
                    Button(action: next) { HStack(spacing: 8) { Text(continueTitle); Image(systemName: "arrow.right") } }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .disabled(missing != nil)
                } else {
                    // Skipping is allowed, but the step's own action stays the obvious one.
                    Button(action: next) { HStack(spacing: 8) { Text(continueTitle); Image(systemName: "arrow.right") } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(missing != nil)
                }
            }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Palette.surface)
        .hairline(.top)
    }

    /// What still has to be filled in before continuing (nil: ready).
    private var missing: String? {
        switch step {
        case .about:
            let p = model.profile.personal
            var need: [String] = []
            if p.firstName.trimmed.isEmpty || p.lastName.trimmed.isEmpty { need.append("your name") }
            if !p.email.contains("@") { need.append("an email") }
            if p.phone.trimmed.isEmpty { need.append("a phone number") }
            return need.isEmpty ? nil : "Add " + ListFormatter.localizedString(byJoining: need) + " to continue"
        case .search:
            return model.settings.search.cleanKeywords.isEmpty ? "Add at least one job title" : nil
        case .resume:
            return model.resumeStatus != nil ? "Reading…" : nil
        default:
            return nil
        }
    }

    private var continueTitle: String {
        switch step {
        case .resume where !model.resumePresent: "Skip for now"
        case .ai where !model.aiState.isReady: "Continue without it"
        case .linkedin where model.linkedInState != .signedIn: "I'll do this later"
        case .email where !model.secrets.emailConfigured: "Skip"
        default: "Continue"
        }
    }
}

private struct ReadyStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    check(model.resumePresent, "Resume", model.resumePresent ? "Attached to every application" : "Add it later under Profile", optional: false)
                    check(model.profile.isComplete, "Your details", model.profile.personal.fullName.isEmpty ? "Missing" : model.profile.personal.fullName, optional: false)
                    check(!model.settings.search.cleanKeywords.isEmpty, "Jobs to find",
                          model.settings.search.cleanKeywords.prefix(3).joined(separator: ", "), optional: false)
                    check(model.aiState.isReady, "AI helper", aiLine, optional: true)
                    check(model.linkedInState == .signedIn, "LinkedIn", model.linkedInState == .signedIn ? "Signed in" : "Sign in before your first run", optional: false)
                    check(model.secrets.emailConfigured, "Email codes", model.secrets.emailConfigured ? "Connected" : "Skipped (optional)", optional: true)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "How should it start?")
                    HStack(spacing: 12) {
                        modeCard(practice: true, title: "Practice first", badge: "Recommended",
                                 detail: "Fills applications but never presses Submit. Check its work, then switch to real.")
                        modeCard(practice: false, title: "Send for real", badge: nil,
                                 detail: "Submits applications. A PDF of each one is saved so you can see what was sent.")
                    }
                    Divider().overlay(Palette.line)
                    ToggleRow(title: "Run every weekday at \(model.settings.schedule.summary.components(separatedBy: " at ").last ?? "9:30 AM")",
                              detail: "Opens by itself, applies, then quits. You can change the time in Settings.",
                              isOn: $model.settings.schedule.enabled)
                        .onChange(of: model.settings.schedule.enabled) { model.applySchedule() }
                }
            }
            CoachTip(title: "Then, every so often",
                     text: "Open **Questions** to answer anything new it was asked. Each answer makes the next run need you less.")
        }
    }

    private var aiLine: String {
        if case .ready(let name) = model.aiState { return name }
        return "Not set up: it will use only your saved answers"
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String, optional: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle" : "exclamationmark.circle.fill"))
                .font(.system(size: 16))
                .foregroundStyle(ok ? Palette.greenDeep : (optional ? Palette.textFaint : Palette.amber))
            Text(title).font(Typo.bodyStrong).frame(width: 110, alignment: .leading)
            Text(detail).font(Typo.body).foregroundStyle(Palette.textSoft).lineLimit(1)
            Spacer()
        }
    }

    private func modeCard(practice: Bool, title: String, badge: String?, detail: String) -> some View {
        let on = model.settings.practiceMode == practice
        return Button { model.settings.practiceMode = practice } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Palette.green : Palette.textFaint)
                    Text(title).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                    Spacer()
                    if let badge { Pill(text: badge, tone: .green, solid: true) }
                }
                Text(detail).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(on ? Palette.greenWash : Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Palette.green : Palette.lineStrong, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

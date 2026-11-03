import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// First-time setup: the step list on the left, the current step, and Back / Continue.
struct SetupWizard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            StepList()
                .frame(width: 220)
                .background(SidebarBackground())
            Divider()
            VStack(spacing: 0) {
                StepContent(step: model.step)
                Divider()
                WizardFooter()
            }
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { InstallPill() } }
    }
}

struct StepList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SetupStep.allCases) { s in
                let reachable = s.index <= model.furthest && (s != .finish || model.state["saved"].bool == true)
                Button { model.go(s) } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(s == model.step ? Color.accentColor : Color.primary.opacity(0.08))
                            if s.index < model.furthest && s != model.step {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color.accentColor)
                            } else {
                                Text("\(s.index + 1)").font(.caption.bold()).foregroundStyle(s == model.step ? .white : .secondary)
                            }
                        }
                        .frame(width: 24, height: 24)
                        Text(s.title)
                            .fontWeight(s == model.step ? .semibold : .regular)
                            .foregroundStyle(reachable ? .primary : .tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(s == model.step ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!reachable)
            }
            Spacer()
            Text("Step \(model.step.index + 1) of \(SetupStep.allCases.count)").font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .padding(12)
    }
}

struct WizardFooter: View {
    @EnvironmentObject var model: AppModel

    private var nextLabel: String {
        switch model.step {
        case .welcome: "Start"
        case .email: "Save and continue"
        case .finish: "Done"
        default: "Continue"
        }
    }

    var body: some View {
        HStack {
            if model.step != .welcome {
                Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }.controlSize(.large)
            }
            Spacer()
            if model.saving { ProgressView().controlSize(.small).padding(.trailing, 6) }
            Button(nextLabel) { Task { await model.next() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.saving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// The settings page once setup is done: the same steps as tabs, with Save changes.
struct DetailsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $model.step) {
                ForEach(SetupStep.editable) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            StepContent(step: model.step)
            Divider()
            HStack {
                if model.dirty {
                    Label("You have changes that aren't saved yet.", systemImage: "pencil.circle").foregroundStyle(.secondary)
                } else if !model.saveWarnings.isEmpty {
                    Label(model.saveWarnings, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Spacer()
                if model.saving { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button("Save changes") { Task { await model.save(thenFinish: false) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.dirty || model.saving)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear { if !SetupStep.editable.contains(model.step) { model.step = .resume } }
    }
}

struct StepContent: View {
    let step: SetupStep

    var body: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .resume: ResumeStep()
        case .about: AboutStep()
        case .work: WorkStep()
        case .experience: ExperienceStep()
        case .jobs: JobsStep()
        case .email: EmailStep()
        case .finish: FinishStep()
        }
    }
}

/// A step's title and introduction above its form.
struct StepPage<Content: View>: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let lead: String
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section {
                EmptyView()
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(.primary)
                    Text(lead).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let message = model.stepMessage {
                        BannerView(.error, message).padding(.top, 8)
                    }
                }
                .textCase(nil)
                .padding(.bottom, 14)
            }
            content
        }
        .formStyle(.grouped)
    }
}

// MARK: - the steps

struct WelcomeStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "Welcome to Auto Applicator",
                 lead: "Let's get it ready for you. You only do this once, and it takes about 15 minutes.") {
            Section {
                PlanRow(number: 1, title: "It installs what it needs", detail: "This happens on its own – you can see it below.")
                PlanRow(number: 2, title: "You add your resume", detail: "…and check the details it read from it.")
                PlanRow(number: 3, title: "You tell it which jobs you want", detail: "…and sign in to LinkedIn.")
            }
            if let notice = model.state["notice"].string, !notice.isEmpty {
                Section { BannerView(.warn, notice) }
            }
            Section {
                InstallList()
            } header: {
                SectionTitle(model.installDone ? "Installed" : "Installing")
            } footer: {
                if !model.installDone {
                    Text("You don't need to wait: press Start and fill in your details while this finishes.").foregroundStyle(.secondary)
                }
            }
            Section {
                Label("Everything stays on this Mac. Your details are only used to fill in your job applications.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ResumeStep: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    private var importStatus: String { model.state["import"]["status"].string ?? "idle" }

    var body: some View {
        StepPage(title: "Your resume",
                 lead: "Auto Applicator attaches it to your applications, and can read it to fill in your details for you.") {
            Section {
                dropZone
                if !(model.resumePresent && importStatus != "idle") {
                    Toggle("Fill in my details from my resume automatically", isOn: $model.readResume).toggleStyle(.checkbox)
                }
                if model.resumePresent && model.isEdit && (importStatus == "idle" || importStatus == "failed") {
                    Button("Fill in my details from it") { model.readResumeNow() }
                }
            }
            if importStatus != "idle" {
                Section {
                    let message = model.state["import"]["message"].text
                    switch importStatus {
                    case "waiting", "running": BannerView(.info, message, spinning: true)
                    case "done": BannerView(.ok, message)
                    default: BannerView(.warn, message)
                    }
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            if model.uploading {
                ProgressView()
                Text("Adding your resume…").foregroundStyle(.secondary)
            } else if model.resumePresent {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                Text(model.state["resume"]["name"].text.isEmpty ? "resume.pdf" : model.state["resume"]["name"].text).font(.headline)
                Button("Replace with another file…") { model.chooseResume() }
            } else {
                Image(systemName: "doc.text").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Drop your resume here").font(.headline)
                Text("It needs to be a PDF file").foregroundStyle(.secondary)
                Button("Choose your resume…") { model.chooseResume() }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.primary.opacity(0.2))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await AppModel.shared.useResume(url) }
            }
            return true
        }
    }
}

struct AboutStep: View {
    var body: some View {
        StepPage(title: "About you", lead: "This is what employers will see. Please check that everything is right.") {
            Section {
                TextRow(label: "First name", path: "profile.personal.first_name")
                TextRow(label: "Last name", path: "profile.personal.last_name")
                TextRow(label: "Email", path: "profile.personal.email", prompt: "you@example.com")
                TextRow(label: "Phone", path: "profile.personal.phone")
                TextRow(label: "City", path: "profile.personal.address.city")
                TextRow(label: "State or province", path: "profile.personal.address.state")
                TextRow(label: "Country", path: "profile.personal.address.country")
                TextRow(label: "LinkedIn profile link", path: "profile.personal.linkedin", prompt: "Optional – https://www.linkedin.com/in/…")
            }
            Section {
                DisclosureGroup("More details (optional)") {
                    TextRow(label: "Preferred first name", path: "profile.personal.preferred_name", prompt: "If different from your first name")
                    TextRow(label: "Phone country code", path: "profile.personal.phone_country_code", prompt: "+1")
                    TextRow(label: "Street address", path: "profile.personal.address.street")
                    TextRow(label: "ZIP or postal code", path: "profile.personal.address.postal_code")
                    TextRow(label: "Website or portfolio", path: "profile.personal.portfolio", prompt: "https://…")
                    TextRow(label: "GitHub", path: "profile.personal.github", prompt: "https://github.com/…")
                }
            }
        }
    }
}

struct WorkStep: View {
    var body: some View {
        StepPage(title: "Work & pay", lead: "Job applications almost always ask these questions.") {
            Section {
                YesNoRow(question: "Are you legally allowed to work in the country where you're applying?", path: "profile.work_authorization.authorized_to_work_us")
                YesNoRow(question: "Will you need a visa sponsorship, now or in the future?", path: "profile.work_authorization.requires_sponsorship")
                YesNoRow(question: "Would you move to another city for a job?", path: "profile.preferences.willing_to_relocate")
                YesNoRow(question: "Are you 18 or older?", path: "profile.preferences.over_18")
                TextRow(label: "Citizenship or visa status", path: "profile.work_authorization.visa_status", prompt: "e.g. US Citizen, Green Card, H-1B")
            }
            Section(title: "Pay and start date") {
                TextRow(label: "Yearly salary you'd like", path: "profile.compensation.desired_base", prompt: "e.g. 85000")
                TextRow(label: "Lowest you'd accept", path: "profile.compensation.range_min", prompt: "Optional – e.g. 75000")
                TextRow(label: "Notice period", path: "profile.preferences.notice_period", prompt: "e.g. 2 weeks")
                TextRow(label: "Earliest start date", path: "profile.preferences.earliest_start_date", prompt: "e.g. 2 weeks after offer")
            }
            Section {
                DisclosureGroup("More details (optional)") {
                    TextRow(label: "Salary currency", path: "profile.compensation.currency", prompt: "USD")
                    TextRow(label: "Top of your salary range", path: "profile.compensation.range_max")
                    TextRow(label: "Country of citizenship", path: "profile.work_authorization.citizenship")
                    TextRow(label: "Security clearance", path: "profile.work_authorization.security_clearance", prompt: "None")
                }
            }
            Section {
                DisclosureGroup("Voluntary self-identification (optional)") {
                    Text("US employers ask these for diversity reporting. “Decline to self-identify” is always fine, and it's what Auto Applicator answers unless you choose otherwise.")
                        .font(.callout).foregroundStyle(.secondary)
                    ChoiceRow(label: "Gender", path: "profile.eeo.gender", optionsPath: "eeo.gender")
                    ChoiceRow(label: "Hispanic or Latino", path: "profile.eeo.hispanic_or_latino", optionsPath: "eeo.hispanic_or_latino")
                    ChoiceRow(label: "Race / ethnicity", path: "profile.eeo.ethnicity", optionsPath: "eeo.ethnicity")
                    ChoiceRow(label: "Veteran status", path: "profile.eeo.veteran_status", optionsPath: "eeo.veteran_status")
                    ChoiceRow(label: "Disability", path: "profile.eeo.disability_status", optionsPath: "eeo.disability_status")
                    TextRow(label: "Pronouns", path: "profile.eeo.pronouns", prompt: "Optional – e.g. she/her")
                }
            }
        }
    }
}

struct ExperienceStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "Your experience", lead: "Used to answer questions like “How many years of Excel do you have?”") {
            Section {
                TextRow(label: "Total years of work experience", path: "profile.years_total", prompt: "e.g. 5")
            }
            Section {
                ForEach(Array(model.list("profile.years_rows").indices), id: \.self) { i in
                    HStack {
                        TextField("Skill", text: model.text("profile.years_rows.\(i).skill"), prompt: Text("Skill, e.g. Excel")).labelsHidden()
                        TextField("Years", text: model.text("profile.years_rows.\(i).years"), prompt: Text("Years"))
                            .labelsHidden()
                            .frame(width: 70)
                        Button { model.remove("profile.years_rows", at: i) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove this skill")
                    }
                }
                Button { model.append("profile.years_rows", ["skill": "", "years": ""]) } label: { Label("Add a skill", systemImage: "plus") }
                    .buttonStyle(.borderless)
            } header: {
                SectionTitle("Years per skill")
            } footer: {
                Text("When a job asks about a skill that isn't listed here, Auto Applicator skips that job and asks you later, instead of guessing.")
                    .foregroundStyle(.secondary)
            }
            Section(title: "Skills and summary") {
                CommaListRow(label: "Key skills", path: "profile.skills", prompt: "Separate with commas, e.g. Excel, SQL")
                TextRow(label: "A sentence or two about you", path: "profile.summary", prompt: "Optional", multiline: true)
            }
            Section(title: "Jobs you've had") {
                Text("Most recent first. Correct, add or remove them here.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.list("profile.work_history").indices), id: \.self) { i in
                let base = "profile.work_history.\(i)"
                Section {
                    TextRow(label: "Job title", path: "\(base).title")
                    TextRow(label: "Company", path: "\(base).company")
                    TextRow(label: "From", path: "\(base).start_date", prompt: "YYYY-MM")
                    TextRow(label: "To", path: "\(base).end_date", prompt: "YYYY-MM, or Present")
                    TextRow(label: "Location", path: "\(base).location")
                } header: {
                    ItemHeader(title: "Job \(i + 1)") { model.remove("profile.work_history", at: i) }
                }
            }
            Section {
                Button {
                    model.append("profile.work_history", ["company": "", "title": "", "location": "", "start_date": "", "end_date": "Present", "bullets": []])
                } label: { Label("Add a job", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            Section(title: "Education") {
                Text("Your degrees, schools and courses.").foregroundStyle(.secondary)
            }
            ForEach(Array(model.list("profile.education").indices), id: \.self) { i in
                let base = "profile.education.\(i)"
                Section {
                    TextRow(label: "School", path: "\(base).school")
                    TextRow(label: "Degree", path: "\(base).degree", prompt: "e.g. Bachelor of Science")
                    TextRow(label: "Field of study", path: "\(base).field_of_study")
                    TextRow(label: "Graduated", path: "\(base).graduation_date", prompt: "YYYY-MM")
                } header: {
                    ItemHeader(title: "School \(i + 1)") { model.remove("profile.education", at: i) }
                }
            }
            Section {
                Button {
                    model.append("profile.education", ["school": "", "degree": "", "field_of_study": "", "start_date": "", "graduation_date": "", "gpa": ""])
                } label: { Label("Add a school", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

struct ItemHeader: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            SectionTitle(title)
            Spacer()
            Button("Remove", role: .destructive, action: remove).buttonStyle(.borderless).foregroundStyle(.red)
        }
    }
}

struct JobsStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "The jobs you want", lead: "Auto Applicator searches LinkedIn for these and applies to the ones that fit.") {
            Section {
                StringListRows(path: "search.keywords", prompt: "e.g. Data Analyst", addLabel: "Add another job title")
            } header: {
                SectionTitle("Job titles to search for")
            } footer: {
                Text("Each title is its own search.").foregroundStyle(.secondary)
            }
            Section {
                TextRow(label: "Where", path: "search.location", prompt: "e.g. United States, or Denver, Colorado")
                LabeledContent("Work type") {
                    HStack(spacing: 14) {
                        ForEach(model.options["workplace"].strings, id: \.self) { value in
                            Toggle(value, isOn: model.member("search.workplace_type", value)).toggleStyle(.checkbox)
                        }
                    }
                }
                Picker("Posted within", selection: model.text("search.date_posted")) {
                    ForEach(Array(model.options["dates"].array.enumerated()), id: \.offset) { _, d in
                        Text(d["label"].text).tag(d["value"].text)
                    }
                }
                ToggleRow(title: "Also apply on company websites",
                          detail: "Besides LinkedIn “Easy Apply”, also fill in applications on company job sites (Greenhouse, Lever, Workday and others). These are slower, and some will need your help.",
                          path: "search.include_external")
            }
            Section {
                ForEach(model.options["levels"].strings, id: \.self) { level in
                    Toggle(level, isOn: model.member("search.experience_level", level)).toggleStyle(.checkbox)
                }
            } header: {
                SectionTitle("Experience level")
            } footer: {
                Text("Leave all unticked for any level.").foregroundStyle(.secondary)
            }
            Section(title: "Safety") {
                ToggleRow(title: "Practice mode – recommended until you've checked a few",
                          detail: "Fills in applications but stops before sending them, and saves a picture of each one so you can check its work.",
                          path: "search.dry_run")
                TextRow(label: "Most applications per run", path: "search.max_applies_per_run")
                ToggleRow(title: "Run automatically every day", detail: "Your Mac needs to be on, and you signed in to it, at that time.",
                          path: "search.schedule_enabled")
                if model.draft["search.schedule_enabled"].bool == true {
                    DatePicker("Time", selection: model.time("search.schedule_time"), displayedComponents: .hourAndMinute)
                    Toggle("Weekdays only", isOn: model.flag("search.weekdays_only"))
                }
            }
            Section {
                DisclosureGroup("Filters (optional)") {
                    Text("Never apply to these companies").font(.callout).foregroundStyle(.secondary)
                    StringListRows(path: "search.blacklist_companies", prompt: "Company name", addLabel: "Add a company")
                    CommaListRow(label: "Skip jobs whose title contains", path: "search.title_exclude", prompt: "e.g. Senior, Manager")
                    CommaListRow(label: "Only jobs whose title contains one of", path: "search.title_must_contain", prompt: "Empty = no rule")
                }
            }
        }
    }
}

struct EmailStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "Email codes",
                 lead: "Some job sites email you a code or a link while you apply. Auto Applicator can read those emails so it can finish the application for you.") {
            Section {
                Picker("Set it up", selection: model.flag("email.enabled")) {
                    Text("Set it up now (recommended)").tag(true)
                    Text("Later").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if model.draft["email.enabled"].bool != true {
                    Text("Applications that email a code will be skipped until you set this up.").foregroundStyle(.secondary)
                }
            }
            if model.draft["email.enabled"].bool == true {
                Section {
                    TextRow(label: "Your email address", path: "email.address", prompt: "you@example.com")
                    if let help = providerHelp { Text(help).fixedSize(horizontal: false, vertical: true) }
                    TextRow(label: providerHelp == nil ? "Password" : "App password", path: "email.password",
                            prompt: model.state["email_configured"].bool == true ? "Already saved – leave empty to keep it" : "", secure: true)
                    if model.showHostField {
                        TextRow(label: "Email server (IMAP)", path: "email.host", prompt: "imap.example.com")
                    }
                    HStack {
                        Button("Test the connection") { Task { await model.testEmail() } }
                        Spacer()
                    }
                    if let result = model.emailResult { BannerView(result) }
                } footer: {
                    Text("Auto Applicator only looks for emails from job sites, and never marks your other emails as read.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var providerHelp: AttributedString? {
        let markdown: String
        switch model.emailDomain {
        case "gmail.com", "googlemail.com":
            markdown = "**Gmail needs an “app password”** – your normal password won't work here.\n1. Make sure 2-Step Verification is on for your Google account.\n2. Open [Google App Passwords](https://myaccount.google.com/apppasswords), type **Auto Applicator** and press **Create**.\n3. Copy the 16-letter password into the box below."
        case "icloud.com", "me.com", "mac.com":
            markdown = "**iCloud Mail needs an app-specific password.** Sign in at [account.apple.com](https://account.apple.com), choose **Sign-In and Security › App-Specific Passwords**, add one called Auto Applicator, and copy it below."
        case "yahoo.com", "ymail.com":
            markdown = "**Yahoo Mail needs an app password:** open [Account security](https://login.yahoo.com/account/security), choose **Generate app password**, and copy it below."
        case "outlook.com", "hotmail.com", "live.com":
            markdown = "**Outlook.com:** turn on two-step verification and create an app password at [account.microsoft.com/security](https://account.microsoft.com/security). If the test doesn't connect, choose **Later** – Microsoft limits this for some accounts."
        case let d where d.contains("."):
            markdown = "Use your email password, or an app password if your email provider offers them. Press **Test the connection** to check."
        default:
            return nil
        }
        return try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
}

struct FinishStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: model.signedIn ? "You're all set!" : "Almost done", lead: "Your details are saved. Two last things:") {
            if !model.saveWarnings.isEmpty {
                Section { BannerView(.warn, model.saveWarnings) }
            }
            Section(title: "1. Sign in to LinkedIn") {
                Text("Auto Applicator uses its own browser window. Sign in there once and it remembers you.")
                LinkedInButton()
            }
            Section(title: "2. Try a practice run") {
                Text("It searches for jobs and fills in a few applications **without sending anything**, and saves a picture of each one for you to check.")
                HStack {
                    Button("Start a practice run") {
                        model.finishSetup()
                        model.startRun(.practice)
                    }
                    .disabled(!(model.installDone && model.state["saved"].bool == true))
                    if !model.installDone {
                        Text("Available as soon as the installation finishes.").foregroundStyle(.secondary)
                    }
                }
            }
            Section(title: "Good to know") {
                LabeledContent("Your settings folder") {
                    Button("Show in Finder") { model.open(model.paths.support) }
                }
                if let password = model.state["portal_password"].string, !password.isEmpty {
                    LabeledContent("Password for company job sites") {
                        Text(password).textSelection(.enabled).font(.body.monospaced())
                    }
                    Text("Some company sites need an account. Auto Applicator creates them with your email and this password.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("LinkedIn doesn't like automated tools: keep the number of applications per run modest.")
                Text("You're responsible for what's sent in your name – look at the practice-run pictures first.")
            }
        }
    }
}

struct LinkedInButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Button(model.signedIn ? "Sign in again" : "Open LinkedIn sign-in") { model.signIn() }
                .buttonStyle(.borderedProminent)
                .disabled(model.signingIn || !model.browserReady || model.runActive)
            if !model.browserReady {
                Text("Available when the browser has finished installing.").foregroundStyle(.secondary)
            }
        }
        let status = model.state["linkedin"]["status"].string ?? "idle"
        if status != "idle" {
            let message = model.state["linkedin"]["message"].text
            switch status {
            case "running": BannerView(.info, message, spinning: true)
            case "done": BannerView(.ok, message)
            default: BannerView(.warn, message)
            }
        }
    }
}

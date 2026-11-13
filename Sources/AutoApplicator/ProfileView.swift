import Engine
import SwiftUI
import UniformTypeIdentifiers

enum ProfileSection: String, CaseIterable, Identifiable {
    case about = "About you", workPay = "Work & pay", experience = "Experience", education = "Education", resume = "Resume", voluntary = "Voluntary"
    var id: String { rawValue }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Page(title: "Profile", subtitle: "What it puts on applications. Changes save automatically.") {
            Segmented(options: ProfileSection.allCases, selection: $model.profileSection, title: \.rawValue)
            Group {
                switch model.profileSection {
                case .about: AboutYouForm()
                case .workPay: WorkPayForm()
                case .experience: ExperienceForm()
                case .education: EducationForm()
                case .resume: ResumeCard()
                case .voluntary: VoluntaryForm()
                }
            }
            .transition(.opacity)
        }
    }
}

// MARK: - about you

struct AboutYouForm: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        @Bindable var model = model
        let p = $model.profile.personal
        Card {
            VStack(alignment: .leading, spacing: 16) {
                if !compact { SectionTitle(title: "Name and contact", detail: "Asked on every application.") }
                HStack(alignment: .top, spacing: 14) {
                    Field(label: "First name") { TextInput("Jane", text: p.firstName) }
                    Field(label: "Last name") { TextInput("Doe", text: p.lastName) }
                }
                HStack(alignment: .top, spacing: 14) {
                    Field(label: "Email", hint: "Where employers will reply.") { TextInput("jane@example.com", text: p.email) }
                    Field(label: "Phone", hint: "Digits are fine, e.g. 512 555 0101.") { TextInput("(512) 555-0101", text: p.phone) }
                }
                HStack(alignment: .top, spacing: 14) {
                    Field(label: "City") { TextInput("Austin", text: p.address.city) }
                    Field(label: "State") { TextInput("TX", text: p.address.state) }.frame(width: 110)
                    Field(label: "ZIP code", optional: true) { TextInput("78701", text: p.address.postalCode) }.frame(width: 130)
                }
                Field(label: "LinkedIn profile link", hint: "On LinkedIn, open your profile and copy the address from the top of the page.", optional: true) {
                    TextInput("https://www.linkedin.com/in/your-name", text: p.linkedin)
                }
                if !compact {
                    HStack(alignment: .top, spacing: 14) {
                        Field(label: "Preferred first name", optional: true) { TextInput("e.g. Jen", text: p.preferredName) }
                        Field(label: "Country") { TextInput("United States", text: p.address.country) }
                    }
                    Field(label: "Street address", hint: "Only a few forms ask for it.", optional: true) { TextInput("123 Main St", text: p.address.street) }
                    HStack(alignment: .top, spacing: 14) {
                        Field(label: "Website or portfolio", optional: true) { TextInput("https://", text: p.portfolio) }
                        Field(label: "GitHub", optional: true) { TextInput("https://github.com/…", text: p.github) }
                    }
                }
            }
        }
    }
}

// MARK: - work & pay

struct WorkPayForm: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Eligibility", detail: "Forms almost always ask these. Answer for the country you're applying in.")
                    ToggleRow(title: "I'm legally allowed to work in the US", isOn: $model.profile.workAuthorization.authorizedToWork)
                    ToggleRow(title: "I'll need visa sponsorship", detail: "Now or in the future (for example H-1B).",
                              isOn: $model.profile.workAuthorization.requiresSponsorship)
                    Field(label: "Citizenship or visa status", hint: "For example: US citizen, Green card holder, F-1 OPT.", optional: true) {
                        TextInput("US citizen", text: $model.profile.workAuthorization.visaStatus)
                    }
                    ToggleRow(title: "I'm 18 or older", isOn: $model.profile.preferences.over18)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Pay", detail: "Used when a form requires a number. Pick what you'd be happy with.")
                    HStack(alignment: .top, spacing: 14) {
                        Field(label: "Desired yearly salary") { NumberInput(placeholder: "95000", value: $model.profile.compensation.desiredBase, prefix: "$") }
                        if !compact {
                            Field(label: "Range from", optional: true) { NumberInput(placeholder: "85000", value: $model.profile.compensation.rangeMin, prefix: "$") }
                            Field(label: "to", optional: true) { NumberInput(placeholder: "110000", value: $model.profile.compensation.rangeMax, prefix: "$") }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(title: "Availability")
                    ToggleRow(title: "I'm willing to relocate", isOn: $model.profile.preferences.willingToRelocate)
                    HStack(alignment: .top, spacing: 14) {
                        Field(label: "Notice period", hint: "How long before you can leave your current job.") {
                            TextInput("2 weeks", text: $model.profile.preferences.noticePeriod)
                        }
                        Field(label: "Earliest start") { TextInput("2 weeks after offer", text: $model.profile.preferences.earliestStartDate) }
                    }
                    if !compact {
                        Field(label: "Security clearance", optional: true) { TextInput("None", text: $model.profile.workAuthorization.securityClearance) }
                    }
                }
            }
        }
    }
}

// MARK: - experience

struct ExperienceForm: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var newSkill = ""
    @State private var newYears = 1.0

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        SectionTitle(title: "Years of experience", detail: "Forms ask “How many years of …?” constantly. These numbers answer them.")
                        Spacer()
                    }
                    HStack {
                        Text("Total, all jobs").font(Typo.bodyStrong)
                        Spacer()
                        YearsStepper(years: Binding(get: { model.profile.experienceYears["total"] ?? 0 },
                                                    set: { model.profile.experienceYears["total"] = $0 }))
                    }
                    .padding(.vertical, 4)
                    Divider().overlay(Palette.line)
                    let skills = model.profile.skillYears
                    if skills.isEmpty {
                        Text("No skills yet. Add the tools and skills from your resume, like Excel, Python or Customer service.")
                            .font(Typo.small).foregroundStyle(Palette.textFaint)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 8) {
                        ForEach(skills, id: \.skill) { item in
                            HStack {
                                Text(item.skill).font(Typo.body).lineLimit(1)
                                Spacer()
                                YearsStepper(years: Binding(get: { model.profile.experienceYears[item.skill] ?? 0 },
                                                            set: { model.profile.experienceYears[item.skill] = $0 }))
                                Button { model.profile.experienceYears[item.skill] = nil } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                }
                                .buttonStyle(QuietButtonStyle(color: Palette.textFaint))
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        TextInput("Add a skill, e.g. Excel", text: $newSkill).onSubmit(addSkill)
                        YearsStepper(years: $newYears)
                        Button("Add", action: addSkill).buttonStyle(SecondaryButtonStyle()).disabled(newSkill.trimmed.isEmpty)
                    }
                    let missing = model.profile.skills.filter { s in model.profile.experienceYears.keys.contains { $0.lowercased() == s.lowercased() } == false }
                    if !missing.isEmpty {
                        HStack(spacing: 6) {
                            Text("From your resume:").font(.system(size: 11)).foregroundStyle(Palette.textFaint)
                            ForEach(missing.prefix(6), id: \.self) { s in Button("+ \(s)") { newSkill = s }.buttonStyle(QuietButtonStyle()) }
                        }
                    }
                }
            }
            if !compact {
                WorkHistoryCard()
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "About you in a few lines", detail: "Used for cover letters and “Tell us about yourself”.")
                        TextInput("A short professional summary", text: $model.profile.summary, multiline: true)
                        Field(label: "Languages you speak") { TagEditor(tags: $model.profile.languages, placeholder: "English") }
                        Field(label: "Certifications", optional: true) { TagEditor(tags: $model.profile.certifications, placeholder: "e.g. PMP") }
                    }
                }
            }
        }
    }

    private func addSkill() {
        let s = newSkill.trimmed
        guard !s.isEmpty else { return }
        model.profile.experienceYears[s] = newYears
        if !model.profile.skills.contains(where: { $0.lowercased() == s.lowercased() }) { model.profile.skills.append(s) }
        newSkill = ""
        newYears = 1
    }
}

struct WorkHistoryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionTitle(title: "Jobs you've had", detail: "Most recent first. Used for “current employer” questions and cover letters.")
                    Spacer()
                    Button { model.profile.workHistory.insert(Role(), at: 0) } label: { Label("Add job", systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                ForEach($model.profile.workHistory) { $role in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            Field(label: "Job title") { TextInput("Store Manager", text: $role.title) }
                            Field(label: "Company") { TextInput("Acme Inc.", text: $role.company) }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            Field(label: "Started", hint: "Year and month, e.g. 2021-04") { TextInput("2021-04", text: $role.startDate) }
                            Field(label: "Ended", hint: "Or “Present”") { TextInput("Present", text: $role.endDate) }
                            Field(label: "Location", optional: true) { TextInput("Austin, TX", text: $role.location) }
                            Button { model.profile.workHistory.removeAll { $0.id == role.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                                .padding(.top, 26)
                        }
                    }
                    .padding(14)
                    .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

// MARK: - education

struct EducationForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionTitle(title: "Education", detail: "Schools, degrees and certificates.")
                    Spacer()
                    Button { model.profile.education.append(Education()) } label: { Label("Add school", systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if model.profile.education.isEmpty {
                    Text("Nothing yet. Add your school, or skip this if it doesn't apply.").font(Typo.small).foregroundStyle(Palette.textFaint)
                }
                ForEach($model.profile.education) { $e in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            Field(label: "School") { TextInput("University of Texas", text: $e.school) }
                            Field(label: "Degree") { TextInput("Bachelor's", text: $e.degree) }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            Field(label: "Field of study") { TextInput("Business", text: $e.fieldOfStudy) }
                            Field(label: "Graduated", hint: "Year, e.g. 2019") { TextInput("2019", text: $e.graduationDate) }.frame(width: 150)
                            Field(label: "GPA", optional: true) { TextInput("3.6", text: $e.gpa) }.frame(width: 90)
                            Button { model.profile.education.removeAll { $0.id == e.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                                .padding(.top, 26)
                        }
                    }
                    .padding(14)
                    .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

// MARK: - resume

struct ResumeCard: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Your resume", detail: "Attached to every application. A PDF works everywhere.")
                if model.resumePresent {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "doc.text.fill").font(.system(size: 28)).foregroundStyle(Palette.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("resume.pdf").font(Typo.bodyStrong)
                            Text(fileLine).font(Typo.small).foregroundStyle(Palette.textSoft)
                        }
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(model.paths.resumeFile) }.buttonStyle(SecondaryButtonStyle())
                        Button("Replace…") { choosing = true }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(14)
                    .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack {
                        Button { Task { await model.readResume() } } label: { Label("Read it again", systemImage: "text.viewfinder") }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(model.resumeStatus != nil)
                        Text("Fills in anything missing from your profile. It never overwrites what you typed.").font(Typo.small).foregroundStyle(Palette.textFaint)
                    }
                    ResumeStatus()
                } else {
                    ResumeDropZone()
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { Task { await model.importResume(url) } }
        }
    }

    private var fileLine: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: model.paths.resumeFile.path)
        let size = (attrs?[.size] as? Int).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let date = (attrs?[.modificationDate] as? Date).map { "added " + $0.relative } ?? ""
        return [size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Drop a PDF here, or click to choose one.
struct ResumeDropZone: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var choosing = false

    var body: some View {
        VStack(spacing: 14) {
            Button { choosing = true } label: {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Palette.greenWash).frame(width: 60, height: 60)
                        Image(systemName: model.resumePresent ? "checkmark" : "arrow.down.doc")
                            .font(.system(size: 24, weight: .medium)).foregroundStyle(Palette.green)
                    }
                    Text(model.resumePresent ? "Resume added" : "Drop your resume here").font(Typo.heading(18)).foregroundStyle(Palette.text)
                    Text(model.resumePresent ? "Click to choose a different file." : "or click to choose a PDF from your Mac")
                        .font(Typo.body).foregroundStyle(Palette.textSoft)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background(targeted ? Palette.greenWash : Palette.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(targeted ? Palette.green : Palette.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                )
                .contentShape(Rectangle())
                .scaleEffect(targeted ? 1.01 : 1)
                .animation(.snappy, value: targeted)
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await model.importResume(url) } }
                }
                return true
            }
            ResumeStatus()
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { Task { await model.importResume(url) } }
        }
    }
}

struct ResumeStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let status = model.resumeStatus {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(status).font(Typo.body).foregroundStyle(Palette.textSoft)
            }
            .transition(.opacity)
        } else if let error = model.resumeError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(Typo.small).foregroundStyle(Palette.red)
        } else if let found = model.resumeFound {
            Label(found, systemImage: "sparkles").font(Typo.body).foregroundStyle(Palette.greenDeep)
        }
    }
}

// MARK: - voluntary questions

struct VoluntaryForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let eeo = $model.profile.eeo
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Voluntary questions",
                             detail: "US employers ask these for equal-opportunity reporting. They're optional and never affect hiring. “Decline to self-identify” is always a safe choice.")
                picker("Gender", "gender", eeo.gender)
                picker("Hispanic or Latino", "hispanic_or_latino", eeo.hispanicOrLatino)
                picker("Race or ethnicity", "ethnicity", eeo.ethnicity)
                picker("Veteran status", "veteran_status", eeo.veteranStatus)
                picker("Disability", "disability_status", eeo.disabilityStatus)
                Field(label: "Pronouns", optional: true) { TextInput("e.g. she/her", text: eeo.pronouns) }.frame(maxWidth: 300)
            }
        }
    }

    private func picker(_ label: String, _ key: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(label).font(Typo.bodyStrong)
            Spacer()
            Picker("", selection: value) {
                ForEach(EEO.choices[key] ?? [], id: \.self) { Text($0).tag($0) }
                if !(EEO.choices[key] ?? []).contains(value.wrappedValue) { Text(value.wrappedValue).tag(value.wrappedValue) }
            }
            .labelsHidden()
            .frame(width: 340)
        }
    }
}

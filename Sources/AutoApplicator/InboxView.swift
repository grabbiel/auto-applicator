import Engine
import SwiftUI

/// Questions a form asked that the app couldn't answer. Each answer is saved and reused from then on.
struct InboxView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page(title: "Questions for you",
             subtitle: "When an application asks something it can't answer from what you've told it, the question waits here. Answer it once, and it's reused on every future application.") {
            if model.pending.isEmpty {
                Card {
                    EmptyState(symbol: "checkmark.bubble", title: "You're all caught up",
                               message: "New questions show up here after a run. The jobs that asked them are retried on the next run once you answer.")
                }
            } else {
                CoachTip(text: "**Tip:** answer in the same words you'd type on the form. For choices, pick one of the buttons. The job that asked is tried again on the next run.")
                // The same question in other words is shown once; answering it answers them all.
                ForEach(QuestionGroups.group(model.pending), id: \.0.hash) { q, others in
                    QuestionCard(question: q, others: others).id(q.hash)
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
        }
        .animation(.snappy, value: model.pending.map(\.hash))
    }
}

private struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    var question: PendingQuestion
    var others: [PendingQuestion] = []
    @State private var text = ""
    @State private var choice: String?

    private var options: [String] {
        if question.fieldType == "checkbox" && question.options.isEmpty { return ["Yes", "No"] }
        return question.options.filter { !$0.trimmed.isEmpty && !$0.lowercased().hasPrefix("select") && $0 != "--" }
    }

    private var answer: String { options.isEmpty ? text : (choice ?? "") }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "questionmark.bubble.fill").font(.system(size: 18)).foregroundStyle(Palette.amber).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 5) {
                        if let section = sectionTitle {
                            Text(section.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.greenDeep)
                        }
                        Text(questionText).font(Typo.heading(17, .medium)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                        if let hint = sectionHint {
                            Text(hint).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        if !others.isEmpty {
                            Text("Also asked as " + ListFormatter.localizedString(byJoining: others.prefix(3).map { "“\($0.question)”" }))
                                .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(meta).font(Typo.small).foregroundStyle(Palette.textFaint)
                    }
                }
                Group {
                    if options.isEmpty {
                        TextInput(placeholder, text: $text, multiline: question.fieldType == "textarea")
                            .onSubmit(save)
                    } else if options.count <= 8 {
                        ChipPicker(options: options, selection: Binding(get: { choice.map { [$0] } ?? [] }, set: { choice = $0.last }),
                                   title: { $0 }, single: true)
                    } else {
                        Picker("", selection: $choice) {
                            Text("Choose…").tag(String?.none)
                            ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }
                .padding(.leading, 30)
                HStack {
                    Spacer()
                    Button("I can't answer") { model.decline(question) }
                        .buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                        .help("For something you don't have, like an ID number from another country. Jobs that require it are skipped, now and in later runs. Undo it under What it knows.")
                    Button("Save answer", action: save)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(answer.trimmed.isEmpty)
                }
            }
        }
    }

    /// "Education › End date month" is shown as the section above the question.
    private var parts: (section: String?, question: String) {
        let pieces = question.question.components(separatedBy: " › ")
        return pieces.count == 2 ? (pieces[0], pieces[1]) : (nil, question.question)
    }

    private var sectionTitle: String? { parts.section }
    private var questionText: String { parts.question }

    /// Which entry of that section the form meant.
    private var sectionHint: String? {
        switch parts.section {
        case "Education":
            let school = model.profile.education.first?.school ?? ""
            return school.isEmpty ? "Asked in the form's education section." : "Asked in the form's education section, about your first school (\(school))."
        case "Work experience":
            let job = model.profile.workHistory.first.map { "\($0.title) at \($0.company)" } ?? ""
            return job.isEmpty ? "Asked in the form's work experience section." : "Asked in the form's work experience section, about your latest job (\(job))."
        case "References": return "About a reference: someone who can speak about your work, not you."
        case "Emergency contact": return "About your emergency contact, not you."
        case "Referral": return "About the person who referred you."
        case .some(let s): return "Asked in the form's “\(s)” section."
        case nil: return nil
        }
    }

    private var meta: String {
        var parts: [String] = []
        let companies = Array(Set(([question] + others).flatMap(\.companies))).sorted()
        if !companies.isEmpty {
            parts.append("Asked by " + ListFormatter.localizedString(byJoining: Array(companies.prefix(3)))
                         + (companies.count > 3 ? " and \(companies.count - 3) more" : ""))
        }
        if let seen = question.lastSeen { parts.append(seen.relative) }
        return parts.joined(separator: " · ")
    }

    private var placeholder: String {
        switch question.fieldType {
        case "number": "A number, e.g. 3"
        case "textarea": "A few sentences in your own words"
        default: "Your answer"
        }
    }

    private func save() {
        guard !answer.trimmed.isEmpty else { return }
        model.answer(question, with: answer)
    }
}

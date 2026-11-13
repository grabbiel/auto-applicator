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
                ForEach(model.pending) { q in
                    QuestionCard(question: q).id(q.hash)
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
                        Text(question.question).font(Typo.heading(17, .medium)).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
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
                    Button("Not now") { model.dismiss(question) }
                        .buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                        .help("Removes the question. If a form asks it again, it comes back.")
                    Button("Save answer", action: save)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(answer.trimmed.isEmpty)
                }
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if !question.companies.isEmpty {
            parts.append("Asked by " + ListFormatter.localizedString(byJoining: Array(question.companies.prefix(3)))
                         + (question.companies.count > 3 ? " and \(question.companies.count - 3) more" : ""))
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

import Engine
import SwiftUI

/// Everything it knows about the user beyond the profile, how complete that is, and what to add next.
struct KnowledgeView: View {
    @Environment(AppModel.self) private var model
    @State private var newFact = ""
    @State private var onlyMine = true

    var body: some View {
        Page(title: "What it knows",
             subtitle: "It grows with every answer you give. The more it knows, the more applications it can finish without asking you.") {
            overview
            factsCard
            answersCard
        }
    }

    // MARK: overview

    private var overview: some View {
        let report = model.knowledge
        return Card(padding: 24) {
            HStack(alignment: .top, spacing: 30) {
                VStack(spacing: 10) {
                    ZStack {
                        ProgressRing(value: report.score, lineWidth: 12)
                        VStack(spacing: 0) {
                            Text("\(Int((report.score * 100).rounded()))%").font(Typo.number(30))
                            Text("complete").font(Typo.small).foregroundStyle(Palette.textSoft)
                        }
                    }
                    .frame(width: 140, height: 140)
                    Text(scoreLine(report.score)).font(Typo.small).foregroundStyle(Palette.textSoft).multilineTextAlignment(.center).frame(width: 170)
                }
                VStack(alignment: .leading, spacing: 16) {
                    let todo = report.suggestions
                    if !todo.isEmpty {
                        Eyebrow("Most useful next")
                        VStack(spacing: 0) {
                            ForEach(todo) { item in
                                Button { model.go(to: item.destination) } label: {
                                    Hover { hovering in
                                        HStack(spacing: 12) {
                                            Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.green)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text)
                                                Text(item.detail).font(.system(size: 11)).foregroundStyle(Palette.textSoft).lineLimit(1)
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Palette.green)
                                                .offset(x: hovering ? 2 : 0)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Palette.sunken : .clear))
                                        .contentShape(Rectangle())
                                        .animation(.easeOut(duration: 0.12), value: hovering)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, -10)
                    }
                    let done = report.items.filter(\.done)
                    if !done.isEmpty {
                        Eyebrow("Already knows")
                        FlowLayout(spacing: 6) {
                            ForEach(done) { item in Pill(text: knownTitle(item), tone: .green, symbol: "checkmark") }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func knownTitle(_ item: KnowledgeReport.Item) -> String {
        [
            "resume": "Your resume", "contact": "Name, email and phone", "salary": "Your salary", "visa": "Visa status",
            "skills": "Years for your skills", "jobs": "Your jobs", "school": "Your education", "email": "Email codes",
            "answers": "10+ answers", "facts": "3+ facts", "linkedin": "LinkedIn link", "total": "Years of experience",
        ][item.id] ?? item.title
    }

    private func scoreLine(_ s: Double) -> String {
        switch s {
        case ..<0.4: "Just getting to know you. Each item on the right helps."
        case ..<0.75: "A good start. A few more details and it'll ask far fewer questions."
        case ..<1: "It knows you well. Keep answering questions as they come."
        default: "Everything's in place. It keeps learning from each answer."
        }
    }

    // MARK: facts

    private var factsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Things you've taught it",
                             detail: "Short facts it can use to answer questions, e.g. “I have a valid driver's license” or “I can lift 25 lbs”.")
                HStack(spacing: 8) {
                    TextInput("Teach it something about you…", text: $newFact).onSubmit(addFact)
                    Button("Add", action: addFact).buttonStyle(PrimaryButtonStyle()).disabled(newFact.trimmed.isEmpty)
                }
                if model.facts.isEmpty {
                    HStack(spacing: 6) {
                        Text("Ideas:").font(.system(size: 11)).foregroundStyle(Palette.textFaint)
                        ForEach(["I have a valid driver's license", "I'm comfortable with travel up to 25%", "I'm fluent in Spanish"], id: \.self) { idea in
                            Button("+ \(idea)") { newFact = idea }.buttonStyle(QuietButtonStyle())
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.facts) { fact in
                            FactRow(fact: fact)
                            if fact.id != model.facts.last?.id { Divider().overlay(Palette.line) }
                        }
                    }
                }
            }
        }
    }

    private func addFact() {
        model.addFact(newFact)
        newFact = ""
    }

    // MARK: learned answers

    private var answers: [CachedAnswer] {
        model.learned.filter { a in
            (!onlyMine || a.learnedFromUser)
                && (model.knowledgeQuery.isEmpty || a.question.localizedCaseInsensitiveContains(model.knowledgeQuery) || a.answer.localizedCaseInsensitiveContains(model.knowledgeQuery))
        }
    }

    private var answersCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    SectionTitle(title: "Answers it remembers",
                                 detail: "Reused whenever a form asks the same thing (or something worded almost the same).")
                    Spacer()
                    Segmented(options: [true, false], selection: $onlyMine, title: { $0 ? "From you" : "All" }).frame(width: 170)
                }
                TextInput("Search answers", text: Bindable(model).knowledgeQuery)
                if answers.isEmpty {
                    Text(onlyMine ? "Answers you give on the Questions page are kept here." : "Nothing saved yet.")
                        .font(Typo.small).foregroundStyle(Palette.textFaint).padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(answers.prefix(200)) { a in
                            AnswerRow(answer: a)
                            if a.id != answers.prefix(200).last?.id { Divider().overlay(Palette.line) }
                        }
                    }
                }
            }
        }
    }
}

private struct FactRow: View {
    @Environment(AppModel.self) private var model
    var fact: Fact
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Palette.green)
            if editing {
                TextInput("", text: $text).onSubmit(commit)
                Button("Save", action: commit).buttonStyle(SecondaryButtonStyle())
            } else {
                Text(fact.text).font(Typo.body).foregroundStyle(Palette.text)
                Spacer()
                Button { text = fact.text; editing = true } label: { Image(systemName: "pencil") }.buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                Button { model.deleteFact(fact) } label: { Image(systemName: "trash") }.buttonStyle(QuietButtonStyle(color: Palette.textSoft))
            }
        }
        .padding(.vertical, 8)
    }

    private func commit() {
        model.updateFact(fact, text: text)
        editing = false
    }
}

private struct AnswerRow: View {
    @Environment(AppModel.self) private var model
    var answer: CachedAnswer
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(answer.question).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(2)
                Spacer()
                Pill(text: sourceLabel, tone: answer.learnedFromUser ? .green : .neutral)
            }
            if editing {
                HStack(spacing: 8) {
                    if answer.options.isEmpty {
                        TextInput("", text: $text).onSubmit(commit)
                    } else {
                        Picker("", selection: $text) { ForEach(answer.options, id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                    Button("Save", action: commit).buttonStyle(SecondaryButtonStyle())
                    Button("Cancel") { editing = false }.buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                }
            } else {
                HStack {
                    Text(answer.answer.isEmpty ? "(left blank)" : answer.answer).font(Typo.body).foregroundStyle(Palette.textSoft).lineLimit(3)
                    Spacer()
                    Button("Edit") { text = answer.answer; editing = true }.buttonStyle(QuietButtonStyle())
                    Button("Forget") { model.forget(answer) }.buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var sourceLabel: String {
        switch answer.source {
        case "user": "You"
        case "edited": "You (edited)"
        case "llm:high": "AI, confident"
        default: answer.source.hasPrefix("llm") ? "AI" : "Profile"
        }
    }

    private func commit() {
        model.edit(answer, answer: text)
        editing = false
    }
}

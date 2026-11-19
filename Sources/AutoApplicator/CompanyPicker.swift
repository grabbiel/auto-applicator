import Engine
import SwiftUI

/// The companies to skip, with a search of large employers as you type. Picking Tata Consultancy Services also skips
/// its jobs posted as "TCS"; typing "Tata" shows which companies the bare word would skip. The person's own jobs'
/// companies come first, under the names LinkedIn shows.
struct CompanyListEditor: View {
    @Binding var companies: [String]
    /// How many of the person's jobs each company posted.
    var seen: [String: Int] = [:]

    @State private var draft = ""
    @State private var found = CompanyDirectory.Search()
    @State private var highlighted = 0
    @State private var searching: Task<Void, Never>?
    /// The other names each entry also skips, worked out away from the main thread.
    @State private var also: [String: [String]] = [:]
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        var id: String { (typed ? "typed:" : "") + name }
        let name: String
        let detail: String
        let typed: Bool
    }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(companies, id: \.self, content: chip)
                TextField(companies.isEmpty ? "Add a company, e.g. Tata" : "Add a company…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused($focused)
                    .frame(minWidth: 180)
                    .padding(.vertical, 5)
                    .onSubmit { add(highlighted, of: rows) }
                    .onChange(of: draft) { _, new in search(new) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, rows.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) {
                        guard !draft.isEmpty else { return .ignored }
                        draft = ""
                        return .handled
                    }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(InputStyle(focused: focused))
            .onTapGesture { focused = true }

            if !rows.isEmpty { results(rows) }
        }
        .task(id: companies) {
            let list = companies
            also = await Task.detached(priority: .utility) {
                Dictionary(list.map { ($0, CompanyDirectory.shared.otherNames(of: $0)) }, uniquingKeysWith: { a, _ in a })
            }.value
        }
    }

    // MARK: the list

    private func chip(_ name: String) -> some View {
        let others = also[name] ?? []
        return HStack(spacing: 5) {
            Text(name).font(.system(size: 12.5, weight: .medium))
            if let first = others.first, first.count <= 28 {
                Text(others.count > 1 ? "also \(first) +\(others.count - 1)" : "also \(first)")
                    .font(.system(size: 11)).foregroundStyle(Palette.textFaint)
            }
            Button { withAnimation(.snappy) { companies.removeAll { $0 == name } } } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textFaint)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.lineStrong))
        .help(others.isEmpty ? "Skips \(name) and companies whose names start with it."
                             : "Also skips its jobs posted as " + others.joined(separator: ", ") + ".")
    }

    private func add(_ index: Int, of rows: [Row]) {
        let names = rows.indices.contains(index) ? [rows[index].name]
            : draft.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        withAnimation(.snappy) {
            for n in names where !companies.contains(where: { $0.lowercased() == n.lowercased() }) { companies.append(n) }
        }
        draft = ""
        focused = true
    }

    // MARK: searching

    private func search(_ text: String) {
        highlighted = 0
        searching?.cancel()
        if text.contains(",") { add(-1, of: []); return }
        let query = text.trimmed, seen = seen
        guard query.count >= 2 else { found = CompanyDirectory.Search(); return }
        searching = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { CompanyDirectory.shared.search(query, seen: seen, limit: 6) }.value
            guard !Task.isCancelled, draft.trimmed == query else { return }
            found = result
            highlighted = 0
        }
    }

    /// What Return adds comes first: the name as typed when it stands for companies ("Tata"), else the best match
    /// ("Tata Consulting" means Tata Consultancy Services).
    private var rows: [Row] {
        let text = draft.trimmed
        guard !text.isEmpty else { return [] }
        let typed = CompanyName.words(text).joined()
        let onList = Set(companies.map { CompanyName.words($0).joined() })
        let suggestions = found.suggestions.filter { !onList.contains(CompanyName.words($0.name).joined()) }
            .map { Row(name: $0.name, detail: $0.detail, typed: false) }
        guard !onList.contains(typed) else { return suggestions }
        let asTyped = Row(name: text, detail: typedDetail(text), typed: true)
        if suggestions.contains(where: { CompanyName.words($0.name).joined() == typed }) { return suggestions }
        return found.startingWith == 0 && !suggestions.isEmpty ? suggestions + [asTyped] : [asTyped] + suggestions
    }

    private func typedDetail(_ text: String) -> String {
        let n = found.startingWith, examples = found.examples
        guard n > 0, !examples.isEmpty else { return "Skips companies named “\(text)” and any whose names start with it" }
        let more = n > examples.count ? " and \(n - examples.count) more" : ""
        return "Skips every company whose name starts with “\(text)”: " + examples.joined(separator: ", ") + more
    }

    private func results(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { add(index, of: rows) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: row.typed ? "plus" : "building.2")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(index == highlighted ? Palette.greenDeep : Palette.textFaint)
                            .frame(width: 22, height: 22)
                            .background(index == highlighted ? Palette.surface : Palette.sunken,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.typed ? "Add “\(row.name)” as typed" : row.name)
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                            if !row.detail.isEmpty {
                                Text(row.detail).font(Typo.small).foregroundStyle(Palette.textSoft).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if index == highlighted {
                            Image(systemName: "return").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.textFaint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(index == highlighted ? Palette.greenWash : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.lineStrong))
    }
}

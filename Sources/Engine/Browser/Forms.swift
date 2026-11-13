import Foundation

/// A control found on the page, with how to operate it.
public struct FormField: Sendable {
    public enum Kind: String, Sendable { case text, select, radio, checkbox, checkboxGroup = "checkbox_group", combobox, buttons, file }

    public var spec: FieldSpec
    public var kind: Kind
    public var name = ""
    public var htmlID = ""
    public var isInput = false
    /// A search-as-you-type box with too many options to list: type the answer and take the best suggestion.
    public var typeahead = false

    public var id: String { spec.id }
    var selector: String { #"[data-auto-id="\#(spec.id)"]"# }
    func optionSelector(_ i: Int) -> String { #"[data-auto-id="\#(spec.id)"][data-auto-opt="\#(i)"]"# }
    var describe: String { "\"\(spec.label)\" (\(spec.type.rawValue))" }

    /// "resume", "cover_letter" or nil, from the label, name and id.
    var fileKind: String? {
        let hay = "\(spec.label) \(name) \(htmlID)".lowercased()
        if Regex(#"cover[\s_-]*letter"#).matches(hay) { return "cover_letter" }
        if Regex(#"resume|résumé|\bcv\b|curriculum"#).matches(hay) { return "resume" }
        return nil
    }
}

extension WebAgent {
    /// The visible controls under `root` (a CSS selector), skipping anything inside `exclude`.
    public func extractFields(root: String? = nil, exclude: [String] = [], readOptions: Bool = true) async -> [FormField] {
        var args: [String: Any] = ["exclude": exclude]
        if let root { args["root"] = root }
        guard let raw = (try? await js(Scripts.extract, ["opts": args])) as? [[String: Any]] else { return [] }
        var fields: [FormField] = []
        for r in raw {
            guard let id = r["field_id"] as? String, let kind = FormField.Kind(rawValue: r["kind"] as? String ?? "") else { continue }
            let type = FieldSpec.FieldType(rawValue: r["field_type"] as? String ?? "text") ?? .text
            var current = (r["current_value"] as? String) ?? ""
            if kind == .select && isPlaceholderOption(current) { current = "" }
            let spec = FieldSpec(id: id, label: (r["label"] as? String) ?? "", type: type,
                                 options: ((r["options"] as? [String]) ?? []).filter { !$0.isEmpty },
                                 required: (r["required"] as? Bool) ?? false, currentValue: current,
                                 placeholder: (r["placeholder"] as? String) ?? "", error: (r["error"] as? String) ?? "",
                                 maxLength: (r["max_length"] as? NSNumber)?.intValue)
            var f = FormField(spec: spec, kind: kind)
            f.name = (r["name"] as? String) ?? ""
            f.htmlID = (r["html_id"] as? String) ?? ""
            f.isInput = (r["is_input"] as? Bool) ?? false
            fields.append(f)
        }
        if readOptions {
            for i in fields.indices where fields[i].kind == .combobox && fields[i].spec.currentValue.isEmpty {
                await loadComboboxOptions(&fields[i])
            }
        }
        return fields
    }

    private func visibleOptions(_ f: FormField) async -> [String] {
        ((try? await js(Scripts.options, ["sel": f.selector])) as? [String]) ?? []
    }

    /// Opens a dropdown to read its options; long or remote lists are treated as type-to-search boxes.
    func loadComboboxOptions(_ f: inout FormField) async {
        var options: [String] = []
        if await click(f.selector) {
            try? await sleep(0.5)
            options = await visibleOptions(f)
            await press(.escape, selector: f.selector)
        }
        options = options.filter { !$0.isEmpty && !isPlaceholderOption($0) && !["no options", "loading..."].contains($0.lowercased()) }
        if (1...80).contains(options.count) {
            f.spec.options = options
        } else {
            f.typeahead = true
            f.spec.type = .text
        }
    }

    /// Writes an answer into a control. Returns false if the control didn't take it.
    public func fill(_ f: FormField, _ answer: String) async -> Bool {
        switch f.kind {
        case .text:
            var value = answer
            if let max = f.spec.maxLength, max > 0, value.count > max { value = String(value.prefix(max)) }
            return await fill(f.selector, value)
        case .select:
            if await selectOption(f.selector, label: answer) { return true }
            if let choice = matchOption(answer, f.spec.options) { return await selectOption(f.selector, label: choice) }
            return false
        case .radio, .buttons:
            guard let choice = matchOption(answer, f.spec.options), let i = f.spec.options.firstIndex(of: choice) else { return false }
            let sel = f.optionSelector(i)
            if f.kind == .radio, await isChecked(sel) { return true }
            await click(sel)
            try? await sleep(0.1)
            if f.kind == .buttons { return true }
            return await isChecked(sel)
        case .checkbox:
            let want = answer.trimmed.lowercased() == "yes"
            if await isChecked(f.selector) != want { await click(f.selector) }
            try? await sleep(0.1)
            return await isChecked(f.selector) == want
        case .checkboxGroup:
            var ok = true
            for part in answer.split(separator: ";").map({ String($0).trimmed }).filter({ !$0.isEmpty }) {
                guard let choice = matchOption(part, f.spec.options), let i = f.spec.options.firstIndex(of: choice) else { ok = false; continue }
                if !(await isChecked(f.optionSelector(i))) { await click(f.optionSelector(i)) }
            }
            return ok
        case .combobox:
            return await chooseCombobox(f, answer)
        case .file:
            return false
        }
    }

    private func chooseCombobox(_ f: FormField, _ answer: String) async -> Bool {
        await click(f.selector)
        var queries = [answer]
        if f.isInput, let short = answer.split(whereSeparator: { $0 == "," || $0 == "(" }).first.map({ String($0).trimmed }), !short.isEmpty, short != answer {
            queries.append(short)
        }
        for q in queries {
            if f.isInput { await fill(f.selector, q, keepFocus: true) }
            try? await sleep(0.9)
            let options = await visibleOptions(f)
            guard !options.isEmpty else { continue }
            var choice = matchOption(answer, options) ?? matchOption(q, options)
            if choice == nil && f.typeahead { choice = options.first }
            guard let choice, let i = options.firstIndex(of: choice) else { continue }
            await click(#"[data-auto-choice="\#(i)"]"#)
            return true
        }
        await press(.escape)
        return false
    }

    public func upload(_ f: FormField, _ file: URL) async -> Bool {
        await setFiles(f.selector, [file])
    }

    public func collectErrors(root: String? = nil) async -> [String: String] {
        var args: [String: Any] = ["rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        return ((try? await js(Scripts.errors, args)) as? [String: String]) ?? [:]
    }

    /// Finds the last visible enabled button whose name matches `pattern` (case-insensitive). Returns its name and
    /// tags it so `clickFoundButton` can press it.
    public func findButton(_ pattern: String, root: String? = nil) async -> String? {
        var args: [String: Any] = ["pattern": pattern, "flags": "i", "rootSel": NSNull()]
        if let root { args["rootSel"] = root }
        return (try? await js(Scripts.findButton, args)) as? String
    }

    @discardableResult
    public func clickFoundButton() async -> Bool { await click(#"[data-auto-btn="1"]"#) }

    public func fieldCount() async -> Int { ((try? await js(Scripts.countFields)) as? NSNumber)?.intValue ?? 0 }

    public func hasPasswordField() async -> Bool { await bool(Scripts.hasPassword) }
}

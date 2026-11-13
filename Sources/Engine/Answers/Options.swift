import Foundation

private let declineMarkers = ["decline", "prefer not", "not wish", "don't wish", "do not wish", "not to answer", "not to disclose",
                              "choose not", "rather not", "not specified", "i don't want", "i do not want"]
private let placeholder = Regex(#"^(-+\s*)?((please )?(select|choose|pick)\b.*|none selected|-+|\.\.\.)?(\s*-+)?$"#)

/// "Select…", "-- choose --" and empty options are not real answers.
public func isPlaceholderOption(_ option: String) -> Bool { placeholder.fullMatch(norm(option)) }

/// Maps a free answer onto one of the options (verbatim), or nil.
public func matchOption(_ answer: String, _ options: [String]) -> String? {
    let opts = options.filter { !isPlaceholderOption($0) }
    guard !opts.isEmpty, !answer.trimmed.isEmpty else { return nil }
    if opts.contains(answer) { return answer }
    let a = norm(answer)
    var byNorm: [String: String] = [:]
    var normOrder: [String] = []
    for o in opts {
        let n = norm(o)
        if byNorm[n] == nil { byNorm[n] = o; normOrder.append(n) }
    }
    if let exact = byNorm[a] { return exact }
    // Yes/No style: "Yes" -> "Yes, I am authorized to work…"
    func firstWord(_ s: String) -> String {
        String(s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ",."))
    }
    let first = firstWord(a)
    if first == "yes" || first == "no" {
        let hits = opts.filter { firstWord(norm($0)) == first }
        if hits.count == 1 { return hits[0] }
    }
    if declineMarkers.contains(where: { a.contains($0) }) {
        if let hit = opts.first(where: { o in declineMarkers.contains { norm(o).contains($0) } }) { return hit }
    }
    if let close = Difflib.closeMatch(a, normOrder, cutoff: 0.85) { return byNorm[close] }
    let contains = normOrder.filter { a.count >= 3 && ($0.contains(a) || a.contains($0)) }
    if contains.count == 1 { return byNorm[contains[0]] }
    return nil
}

private let rangePattern = Regex(#"(\d+(?:\.\d+)?)\s*(?:-|–|to)\s*(\d+(?:\.\d+)?)"#)
private let plusPattern = Regex(#"(\d+(?:\.\d+)?)\s*\+|(?:more than|over|at least)\s*(\d+(?:\.\d+)?)"#)
private let lessPattern = Regex(#"(?:less than|under|fewer than|<)\s*(\d+(?:\.\d+)?)"#)
private let bareNumber = Regex(#"\s*(\d+(?:\.\d+)?)\s*(years?)?\s*"#)

/// "6" -> "5+ years" or "5-7 years" (only when the answer is a bare number).
public func matchNumericRange(_ answer: String, _ options: [String]) -> String? {
    let a = answer.lowercased()
    guard bareNumber.fullMatch(a), let g = bareNumber.firstGroups(a), let numText = g[1], let v = Double(numText) else { return nil }
    for opt in options {
        let o = opt.lowercased().replacingOccurrences(of: ",", with: "")
        if let r = rangePattern.firstGroups(o), let lo = Double(r[1] ?? ""), let hi = Double(r[2] ?? ""), lo <= v, v <= hi { return opt }
        if let l = lessPattern.firstGroups(o), let lim = Double(l[1] ?? ""), v < lim { return opt }
        if let p = plusPattern.firstGroups(o), let lim = Double(p[1] ?? p[2] ?? ""), v >= lim { return opt }
    }
    let exact = Regex(#"\s*"# + NSRegularExpression.escapedPattern(for: numText) + #"\s*(years?)?\s*"#)
    return options.first { exact.fullMatch($0.lowercased()) }
}

private let numberPattern = Regex(#"-?\d[\d,]*(?:\.\d+)?"#, [])

/// Validates and normalizes an answer for a field; nil means it can't be used.
public func coerceAnswer(_ f: FieldSpec, _ answer: String?) -> String? {
    guard let raw = answer else { return nil }
    var answer = raw.trimmed
    guard !answer.isEmpty else { return nil }
    switch f.type {
    case .checkboxGroup where !f.options.isEmpty:
        var picked: [String] = []
        for part in answer.components(separatedBy: ";").map(\.trimmed) where !part.isEmpty {
            if let m = matchOption(part, f.options), !picked.contains(m) { picked.append(m) }
        }
        return picked.isEmpty ? nil : picked.joined(separator: " ; ")
    case .select, .radio, .combobox, .checkboxGroup:
        if f.options.isEmpty { break }
        return matchOption(answer, f.options) ?? matchNumericRange(answer, f.options)
    case .number:
        return numberPattern.allMatches(answer).first?.replacingOccurrences(of: ",", with: "")
    case .checkbox:
        let a = norm(answer)
        if ["yes", "true", "checked", "agree", "i agree", "1", "on"].contains(a) { return "Yes" }
        if ["no", "false", "unchecked", "0", "off"].contains(a) { return "No" }
        return nil
    case .email:
        if !answer.contains("@") { return nil }
    default:
        break
    }
    if let max = f.maxLength, answer.count > max {
        let cut = String(answer.prefix(max))
        answer = cut.contains(" ") ? String(cut[..<cut.lastIndex(of: " ")!]) : cut
    }
    return answer
}

import CryptoKit
import Foundation

/// A form control as seen by the answer engine.
public struct FieldSpec: Equatable, Sendable {
    public enum FieldType: String, Sendable, CaseIterable {
        case text, textarea, number, email, tel, url, date, select, radio, checkbox
        case checkboxGroup = "checkbox_group", combobox, file
    }

    public var id: String
    public var label: String
    public var type: FieldType
    public var options: [String]
    public var required: Bool
    public var currentValue: String
    public var placeholder: String
    public var error: String
    public var maxLength: Int?

    public init(id: String, label: String, type: FieldType = .text, options: [String] = [], required: Bool = false,
                currentValue: String = "", placeholder: String = "", error: String = "", maxLength: Int? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.options = options
        self.required = required
        self.currentValue = currentValue
        self.placeholder = placeholder
        self.error = error
        self.maxLength = maxLength
    }

    public var hasOptions: Bool { [.select, .radio, .combobox, .checkboxGroup].contains(type) && !options.isEmpty }
}

public struct JobContext: Equatable, Sendable {
    public var title: String
    public var company: String
    public var location: String
    public var description: String

    public init(title: String = "", company: String = "", location: String = "", description: String = "") {
        self.title = title
        self.company = company
        self.location = location
        self.description = description
    }

    public func prompt(maxChars: Int) -> String {
        let desc = description.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        return "Title: \(title)\nCompany: \(company)\nLocation: \(location)\nDescription: \(desc.prefix(maxChars))"
    }
}

// MARK: - regex helpers

public struct Regex: @unchecked Sendable {
    let re: NSRegularExpression

    public init(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    public func matches(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public func fullMatch(_ s: String) -> Bool {
        guard let m = re.firstMatch(in: s, options: [.anchored], range: NSRange(s.startIndex..., in: s)) else { return false }
        return m.range.length == (s as NSString).length
    }

    /// The groups of the first match (index 0 is the whole match; nil for groups that didn't take part).
    public func firstGroups(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }

    public func allMatches(_ s: String, group: Int = 0) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: group), in: s).map { String(s[$0]) }
        }
    }

    public func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

// MARK: - question normalization and hashing (identical to version 0.3, so learned answers carry over)

private let labelNoise = Regex(#"(\(required\)|\(optional\)|\*|✱|required$)"#)
private let whitespace = Regex(#"\s+"#, [])
private let stripSet: Set<Character> = [" ", ":", "?", ".", "-", "–"]

public func normalizeQuestion(_ text: String) -> String {
    var t = labelNoise.replace(text, with: " ")
    t = whitespace.replace(t, with: " ").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while let f = t.first, stripSet.contains(f) { t.removeFirst() }
    while let l = t.last, stripSet.contains(l) { t.removeLast() }
    return t
}

/// normalizeQuestion with typographic apostrophes folded, as the matcher uses it.
public func norm(_ text: String) -> String { normalizeQuestion(text).replacingOccurrences(of: "’", with: "'") }

/// SHA-256 of normalized label + type + sorted normalized options (the qa_cache key).
public func questionHash(_ label: String, _ type: String, _ options: [String] = []) -> String {
    let opts = Set(options.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(normalizeQuestion))
    let sorted = opts.sorted { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
    let raw = [normalizeQuestion(label), type.lowercased(), pythonJSONList(sorted)].joined(separator: "\u{1f}")
    return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Python's `json.dumps(list_of_str)` (", " separators, ASCII-only escapes).
func pythonJSONList(_ items: [String]) -> String {
    "[" + items.map(pythonJSONString).joined(separator: ", ") + "]"
}

func pythonJSONString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 || scalar.value > 0x7E {
                if scalar.value > 0xFFFF {
                    let v = scalar.value - 0x10000
                    out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
                } else {
                    out += String(format: "\\u%04x", scalar.value)
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

// MARK: - difflib (Python's SequenceMatcher.ratio and get_close_matches, which version 0.3's matching relies on)

public enum Difflib {
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars.map(\.value)), y = Array(b.unicodeScalars.map(\.value))
        if x.isEmpty && y.isEmpty { return 1 }
        return 2.0 * Double(matches(x, y)) / Double(x.count + y.count)
    }

    /// Best match for `word` among `possibilities` with ratio >= cutoff (ties go to the larger string, like heapq.nlargest).
    public static func closeMatch(_ word: String, _ possibilities: [String], cutoff: Double) -> String? {
        var best: (Double, String)?
        for p in possibilities {
            let r = ratio(p, word)
            guard r >= cutoff else { continue }
            if best == nil || r > best!.0 || (r == best!.0 && p > best!.1) { best = (r, p) }
        }
        return best?.1
    }

    private static func matches(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var b2j: [UInt32: [Int]] = [:]
        for (j, e) in b.enumerated() { b2j[e, default: []].append(j) }
        if b.count >= 200 {
            let ntest = b.count / 100 + 1
            for (e, idx) in b2j where idx.count > ntest { b2j[e] = nil }
        }
        var total = 0
        var queue = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longest(a, b, b2j, alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            total += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return total
    }

    private static func longest(_ a: [UInt32], _ b: [UInt32], _ b2j: [UInt32: [Int]], _ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
            }
            j2len = newj2len
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] { besti -= 1; bestj -= 1; bestsize += 1 }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] { bestsize += 1 }
        return (besti, bestj, bestsize)
    }
}

/// Lowercase word tokens longer than two characters, minus filler words (used to check the AI cites real facts).
public func contentTokens(_ text: String) -> Set<String> {
    let stop: Set<String> = ["the", "and", "for", "with", "you", "your", "are", "this", "that", "from", "have", "has", "not", "yes",
                             "profile", "candidate", "job", "none", "true", "false", "years", "year"]
    var out = Set<String>()
    var current = ""
    for ch in text.lowercased() {
        if ch.isLetter || ch.isNumber || ch == "+" || ch == "#" {
            current.append(ch)
        } else {
            if current.count > 2 && !stop.contains(current) { out.insert(current) }
            current = ""
        }
    }
    if current.count > 2 && !stop.contains(current) { out.insert(current) }
    return out
}

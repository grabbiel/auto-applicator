import Foundation

/// Reads the YAML that version 0.3 wrote (PyYAML `safe_dump` block style, plus the hand-written template's flow lists,
/// quotes, comments and folded scalars). Only used once, to carry an existing setup over to the JSON files.
/// Values come back as `[String: Any]`, `[Any]`, `String`, `Int`, `Double`, `Bool` or `NSNull` (YAML 1.1 booleans).
public enum YAML {
    public struct ParseError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "YAML line \(line): \(message)" }
    }

    public static func parse(_ text: String) throws -> Any {
        var parser = Parser(text: text)
        return try parser.document()
    }
}

private struct Parser {
    struct Line {
        let number: Int
        let indent: Int
        var text: String  // without the indentation
    }

    var lines: [Line]
    var i = 0

    init(text: String) {
        var out: [Line] = []
        for (n, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let expanded = raw.replacingOccurrences(of: "\t", with: "    ")
            let indent = expanded.prefix(while: { $0 == " " }).count
            out.append(Line(number: n + 1, indent: indent, text: String(expanded.dropFirst(indent))))
        }
        lines = out
    }

    private func isContent(_ line: Line) -> Bool {
        let t = line.text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.hasPrefix("#") && t != "---" && t != "..."
    }

    private mutating func skipBlank() {
        while i < lines.count, !isContent(lines[i]) { i += 1 }
    }

    mutating func document() throws -> Any {
        skipBlank()
        guard i < lines.count else { return [String: Any]() }
        return try node(indent: lines[i].indent)
    }

    private static func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private mutating func node(indent: Int) throws -> Any {
        skipBlank()
        guard i < lines.count else { return NSNull() }
        let line = lines[i]
        if Self.isSequenceItem(line.text) { return try sequence(indent: line.indent) }
        if line.text.hasPrefix("? ") || keySplit(line.text) != nil { return try mapping(indent: line.indent) }
        i += 1
        return try scalar(line.text, parentIndent: indent - 1, lineNo: line.number)
    }

    private mutating func sequence(indent: Int) throws -> [Any] {
        var items: [Any] = []
        while true {
            skipBlank()
            guard i < lines.count, lines[i].indent == indent, Self.isSequenceItem(lines[i].text) else { break }
            let line = lines[i]
            let rest = line.text == "-" ? "" : String(line.text.dropFirst(2))
            let restTrim = rest.trimmingCharacters(in: .whitespaces)
            if restTrim.isEmpty {
                i += 1
                skipBlank()
                if i < lines.count, lines[i].indent > indent { items.append(try node(indent: lines[i].indent)) } else { items.append(NSNull()) }
            } else if Self.isSequenceItem(restTrim) || keySplit(restTrim) != nil || restTrim.hasPrefix("? ") {
                // "- key: value" starts a mapping (or nested list) whose lines sit two columns further in.
                let leading = rest.prefix(while: { $0 == " " }).count
                lines[i] = Line(number: line.number, indent: indent + 2 + leading, text: restTrim)
                items.append(try node(indent: indent + 2 + leading))
            } else {
                i += 1
                items.append(try scalar(restTrim, parentIndent: indent, lineNo: line.number))
            }
        }
        return items
    }

    private mutating func mapping(indent: Int) throws -> [String: Any] {
        var map: [String: Any] = [:]
        while true {
            skipBlank()
            guard i < lines.count, lines[i].indent == indent, !Self.isSequenceItem(lines[i].text) else { break }
            let line = lines[i]
            var key: String
            var rest: String
            if line.text.hasPrefix("? ") {
                // Explicit key (PyYAML writes these for keys longer than 128 characters).
                i += 1
                key = "\(try scalar(String(line.text.dropFirst(2)), parentIndent: indent, lineNo: line.number))"
                skipBlank()
                guard i < lines.count, lines[i].indent == indent, lines[i].text.hasPrefix(":") else {
                    map[key] = NSNull()
                    continue
                }
                rest = String(lines[i].text.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            } else {
                guard let (k, r) = keySplit(line.text) else { throw YAML.ParseError(line: line.number, message: "expected key: value") }
                key = "\(try scalar(k, parentIndent: indent, lineNo: line.number, allowContinuation: false))"
                rest = r
            }
            i += 1
            if rest.isEmpty || rest.hasPrefix("#") {
                skipBlank()
                if i < lines.count, lines[i].indent > indent {
                    map[key] = try node(indent: lines[i].indent)
                } else if i < lines.count, lines[i].indent == indent, Self.isSequenceItem(lines[i].text) {
                    map[key] = try sequence(indent: indent)  // PyYAML puts list items at the key's own indentation
                } else {
                    map[key] = NSNull()
                }
            } else if let style = rest.first, style == "|" || style == ">" {
                map[key] = blockScalar(header: rest, parentIndent: indent)
            } else {
                map[key] = try scalar(rest, parentIndent: indent, lineNo: line.number)
            }
        }
        return map
    }

    /// Splits "key: value" at the first ": " (or trailing ":") outside quotes and brackets.
    private func keySplit(_ text: String) -> (String, String)? {
        var quote: Character?
        var depth = 0
        let chars = Array(text)
        var idx = 0
        if let first = chars.first, first == "'" || first == "\"" {
            // A quoted key: skip to its end.
            idx = 1
            while idx < chars.count {
                if chars[idx] == first {
                    if first == "'", idx + 1 < chars.count, chars[idx + 1] == "'" { idx += 2; continue }
                    if first == "\"", chars[idx - 1] == "\\" { idx += 1; continue }
                    break
                }
                idx += 1
            }
        }
        while idx < chars.count {
            let c = chars[idx]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                if idx == 0 { quote = c }
            } else if c == "[" || c == "{" {
                if idx == 0 { return nil }
                depth += 1
            } else if c == "]" || c == "}" {
                depth -= 1
            } else if c == "#", idx > 0, chars[idx - 1] == " " {
                return nil
            } else if c == ":", depth <= 0, idx + 1 == chars.count || chars[idx + 1] == " " {
                let key = String(chars[0..<idx]).trimmingCharacters(in: .whitespaces)
                let rest = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : (key, rest)
            }
            idx += 1
        }
        return nil
    }

    /// A scalar that may continue on following, more-indented lines (PyYAML wraps long values at the dump width).
    private mutating func scalar(_ first: String, parentIndent: Int, lineNo: Int, allowContinuation: Bool = true) throws -> Any {
        var text = first.trimmingCharacters(in: .whitespaces)
        func continuation() -> [String] {
            var more: [String] = []
            while allowContinuation, i < lines.count {
                let l = lines[i]
                let blank = l.text.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank && l.indent <= parentIndent { break }
                if !blank && (text.first != "'" && text.first != "\"") && (Self.isSequenceItem(l.text) || keySplit(l.text) != nil) && l.indent <= parentIndent + 2 { break }
                more.append(blank ? "" : l.text.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            while more.last == "" { more.removeLast() }
            return more
        }
        if let q = text.first, q == "'" || q == "\"" {
            while !closesQuote(text, q) {
                let more = continuation()
                if more.isEmpty { break }
                text += fold(more)
            }
            return q == "'" ? singleQuoted(text) : doubleQuoted(text)
        }
        if text.hasPrefix("[") || text.hasPrefix("{") {
            var depth = text.filter { "[{".contains($0) }.count - text.filter { "]}".contains($0) }.count
            while depth > 0, i < lines.count {
                text += " " + lines[i].text.trimmingCharacters(in: .whitespaces)
                depth = text.filter { "[{".contains($0) }.count - text.filter { "]}".contains($0) }.count
                i += 1
            }
            var flow = FlowParser(chars: Array(stripComment(text)))
            return flow.value()
        }
        text = stripComment(text)
        let more = continuation()
        if !more.isEmpty { text += fold(more) }
        return plain(text)
    }

    private func fold(_ more: [String]) -> String {
        var out = ""
        for part in more {
            if part.isEmpty { out += "\n" } else { out += (out.hasSuffix("\n") ? "" : " ") + part }
        }
        return out
    }

    private func closesQuote(_ text: String, _ q: Character) -> Bool {
        let body = Array(text.dropFirst())
        var idx = 0
        while idx < body.count {
            if body[idx] == q {
                if q == "'", idx + 1 < body.count, body[idx + 1] == "'" { idx += 2; continue }
                return true
            }
            if q == "\"", body[idx] == "\\" { idx += 2; continue }
            idx += 1
        }
        return false
    }

    private mutating func blockScalar(header: String, parentIndent: Int) -> String {
        let folded = header.hasPrefix(">")
        let keep = header.contains("+"), strip = header.contains("-")
        var raw: [(Int, String)] = []
        while i < lines.count {
            let l = lines[i]
            if !l.text.trimmingCharacters(in: .whitespaces).isEmpty && l.indent <= parentIndent { break }
            raw.append((l.indent, l.text))
            i += 1
        }
        let base = raw.filter { !$0.1.isEmpty }.map(\.0).min() ?? parentIndent + 2
        var body = raw.map { $0.1.isEmpty ? "" : String(repeating: " ", count: max(0, $0.0 - base)) + $0.1 }
        var trailing = 0
        while body.last == "" { body.removeLast(); trailing += 1 }
        var text: String
        if folded {
            text = ""
            for (n, l) in body.enumerated() {
                if n == 0 { text = l; continue }
                text += (l.isEmpty || body[n - 1].isEmpty || l.hasPrefix(" ")) ? "\n" + l : " " + l
            }
        } else {
            text = body.joined(separator: "\n")
        }
        if strip { return text }
        return text + (keep ? String(repeating: "\n", count: trailing + 1) : "\n")
    }

    private func stripComment(_ text: String) -> String {
        guard let r = text.range(of: " #") else { return text.hasPrefix("#") ? "" : text }
        return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private func singleQuoted(_ s: String) -> String {
        var body = s.dropFirst()
        if let end = lastQuote(String(body), "'") { body = body.prefix(end) }
        return String(body).replacingOccurrences(of: "''", with: "'")
    }

    private func lastQuote(_ s: String, _ q: Character) -> Int? {
        let chars = Array(s)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == q {
                if q == "'", idx + 1 < chars.count, chars[idx + 1] == "'" { idx += 2; continue }
                return idx
            }
            if q == "\"", chars[idx] == "\\" { idx += 2; continue }
            idx += 1
        }
        return nil
    }

    private func doubleQuoted(_ s: String) -> String {
        let body = Array(s.dropFirst())
        let end = lastQuote(String(body), "\"") ?? body.count
        var out = ""
        var idx = 0
        while idx < end {
            let c = body[idx]
            if c == "\\", idx + 1 < end {
                let n = body[idx + 1]
                idx += 2
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case " ": out.append(" ")
                case "/": out.append("/")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "x", "u", "U":
                    let len = n == "x" ? 2 : n == "u" ? 4 : 8
                    let hex = String(body[idx..<min(idx + len, end)])
                    if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) { out.unicodeScalars.append(scalar) }
                    idx += len
                default: out.append(n)
                }
                continue
            }
            out.append(c)
            idx += 1
        }
        return out
    }

    fileprivate static func typed(_ text: String) -> Any {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "", "~", "null": return NSNull()
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: break
        }
        if let i = Int(t.replacingOccurrences(of: "_", with: "")), t.range(of: #"^[-+]?[0-9_]+$"#, options: .regularExpression) != nil { return i }
        if t.range(of: #"^[-+]?([0-9][0-9_]*)?\.[0-9_]+([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
            || t.range(of: #"^[-+]?[0-9][0-9_]*(\.[0-9_]*)?[eE][-+]?[0-9]+$"#, options: .regularExpression) != nil,
            let d = Double(t.replacingOccurrences(of: "_", with: "")) { return d }
        return t
    }

    private func plain(_ text: String) -> Any { Parser.typed(text) }
}

/// `[a, 'b c', {k: v}]` style values.
private struct FlowParser {
    let chars: [Character]
    var i = 0

    mutating func value() -> Any {
        skip()
        guard i < chars.count else { return NSNull() }
        switch chars[i] {
        case "[":
            i += 1
            var items: [Any] = []
            while true {
                skip()
                if i >= chars.count { break }
                if chars[i] == "]" { i += 1; break }
                items.append(value())
                skip()
                if i < chars.count, chars[i] == "," { i += 1 }
            }
            return items
        case "{":
            i += 1
            var map: [String: Any] = [:]
            while true {
                skip()
                if i >= chars.count { break }
                if chars[i] == "}" { i += 1; break }
                let key = "\(scalar(stops: ":,}"))"
                skip()
                if i < chars.count, chars[i] == ":" { i += 1; map[key] = value() } else { map[key] = NSNull() }
                skip()
                if i < chars.count, chars[i] == "," { i += 1 }
            }
            return map
        default:
            return scalar(stops: ",]}")
        }
    }

    private mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }

    private mutating func scalar(stops: String) -> Any {
        skip()
        guard i < chars.count else { return NSNull() }
        let q = chars[i]
        if q == "'" || q == "\"" {
            i += 1
            var out = ""
            while i < chars.count {
                let c = chars[i]
                if c == q {
                    if q == "'", i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                    i += 1
                    break
                }
                if q == "\"", c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                out.append(c)
                i += 1
            }
            return out
        }
        var out = ""
        while i < chars.count, !stops.contains(chars[i]) {
            out.append(chars[i])
            i += 1
        }
        return Parser.typed(out)
    }
}

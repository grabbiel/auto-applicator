import Foundation

/// An email reduced to what the verifier needs.
public struct ParsedEmail: Sendable {
    public var subject: String
    public var sender: String
    public var date: Date?
    public var text: String
    /// (anchor text, href)
    public var links: [(String, String)]

    var haystack: String { "\(sender)\n\(subject)\n\(text)".lowercased() }
}

/// A small MIME reader: headers (folded, RFC 2047 encoded words), multipart bodies, base64 / quoted-printable,
/// charsets, and HTML reduced to text plus its links.
public enum MIME {
    public static func parse(_ raw: Data) -> ParsedEmail {
        let part = Part(raw)
        var plain: [String] = []
        var html: [String] = []
        part.walk { p in
            guard !p.isAttachment else { return }
            switch p.contentType {
            case "text/plain": plain.append(p.decodedText)
            case "text/html": html.append(p.decodedText)
            default: break
            }
        }
        var links: [(String, String)] = []
        var htmlText = ""
        if !html.isEmpty {
            let joined = html.joined(separator: "\n")
            links = htmlLinks(joined)
            htmlText = htmlToText(joined)
        }
        let text = plain.isEmpty ? htmlText : plain.joined(separator: "\n")
        if !plain.isEmpty {
            links += Regex(#"https?://[^\s<>"')\]]+"#, []).allMatches(text).map { ("", $0) }
        }
        let from = decodeWords(part.header("from"))
        let sender = Regex(#"<([^>]+)>"#, []).firstGroups(from)?[1] ?? from.trimmed
        return ParsedEmail(subject: decodeWords(part.header("subject")).trimmed, sender: sender, date: parseDate(part.header("date")),
                           text: text, links: links)
    }

    // MARK: parts

    final class Part {
        var headers: [(String, String)] = []
        var body = Data()
        var children: [Part] = []

        init(_ data: Data) {
            let (headerData, bodyData) = Part.split(data)
            headers = Part.parseHeaders(String(decoding: headerData, as: UTF8.self))
            body = bodyData
            if contentType.hasPrefix("multipart/"), let boundary = param("content-type", "boundary") {
                children = Part.splitMultipart(body, boundary: boundary).map(Part.init)
            }
        }

        func header(_ name: String) -> String {
            headers.first { $0.0 == name }?.1 ?? ""
        }

        var contentType: String {
            let v = header("content-type")
            return v.isEmpty ? "text/plain" : String(v.split(separator: ";").first ?? "").trimmed.lowercased()
        }

        var isAttachment: Bool { header("content-disposition").lowercased().hasPrefix("attachment") }

        func param(_ headerName: String, _ name: String) -> String? {
            let v = header(headerName)
            let pattern = Regex(#"(?i)\b"# + name + #"\*?=\s*(?:"([^"]*)"|([^;\s]+))"#, [])
            guard let g = pattern.firstGroups(v) else { return nil }
            return g[1] ?? g[2]
        }

        var decodedText: String {
            let encoding = header("content-transfer-encoding").lowercased().trimmed
            var bytes = body
            if encoding == "base64" {
                let cleaned = String(decoding: body, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).joined()
                bytes = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? body
            } else if encoding == "quoted-printable" {
                bytes = MIME.quotedPrintable(body)
            }
            return MIME.decode(bytes, charset: param("content-type", "charset"))
        }

        func walk(_ visit: (Part) -> Void) {
            if children.isEmpty { visit(self) } else { children.forEach { $0.walk(visit) } }
        }

        static func split(_ data: Data) -> (Data, Data) {
            for sep in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
                if let r = data.range(of: sep) { return (data[..<r.lowerBound], data[r.upperBound...]) }
            }
            return (data, Data())
        }

        static func parseHeaders(_ text: String) -> [(String, String)] {
            var out: [(String, String)] = []
            for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                    out[out.count - 1].1 += " " + line.trimmed
                } else if let colon = line.firstIndex(of: ":") {
                    out.append((line[..<colon].lowercased().trimmed, String(line[line.index(after: colon)...]).trimmed))
                }
            }
            return out
        }

        static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
            let delimiter = Data("--\(boundary)".utf8)
            var parts: [Data] = []
            var cursor = body.startIndex
            var start: Data.Index?
            while let r = body.range(of: delimiter, in: cursor..<body.endIndex) {
                if let s = start {
                    var end = r.lowerBound
                    // drop the line break before the delimiter
                    if end > s, body[end - 1] == 0x0A { end -= 1 }
                    if end > s, body[end - 1] == 0x0D { end -= 1 }
                    parts.append(body[s..<end])
                }
                var next = r.upperBound
                if body[next...].starts(with: Data("--".utf8)) { break }  // closing delimiter
                // skip to the end of the delimiter line
                while next < body.endIndex, body[next] != 0x0A { next += 1 }
                if next < body.endIndex { next += 1 }
                start = next
                cursor = next
            }
            return parts.map { Data($0) }
        }
    }

    // MARK: decoding

    static func decode(_ bytes: Data, charset: String?) -> String {
        let cs = (charset ?? "utf-8").lowercased()
        let enc: String.Encoding
        switch cs {
        case "iso-8859-1", "latin1", "latin-1": enc = .isoLatin1
        case "windows-1252", "cp1252": enc = .windowsCP1252
        case "us-ascii", "ascii": enc = .ascii
        case "utf-16": enc = .utf16
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            enc = cf == kCFStringEncodingInvalidId ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        return String(data: bytes, encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        var out = Data()
        let b = [UInt8](data)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x37
            case 0x61...0x66: return c - 0x57
            default: return nil
            }
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "=") {
                if i + 1 < b.count, b[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(underscoreIsSpace && c == UInt8(ascii: "_") ? 0x20 : c)
            i += 1
        }
        return out
    }

    /// RFC 2047: =?utf-8?B?...?= and =?utf-8?Q?...?=
    static func decodeWords(_ s: String) -> String {
        let pattern = Regex(#"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#, [])
        guard pattern.matches(s) else { return s }
        var result = ""
        var last = s.startIndex
        let ns = s as NSString
        for m in pattern.re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: s) else { continue }
            let between = String(s[last..<r.lowerBound])
            if !(between.trimmingCharacters(in: .whitespaces).isEmpty && last != s.startIndex) { result += between }
            let charset = ns.substring(with: m.range(at: 1))
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            let bytes = mode == "B" ? (Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data())
                                    : quotedPrintable(Data(payload.utf8), underscoreIsSpace: true)
            result += decode(bytes, charset: charset)
            last = r.upperBound
        }
        result += s[last...]
        return result
    }

    static func parseDate(_ s: String) -> Date? {
        var text = s.trimmed
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]).trimmed }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    // MARK: HTML

    static func htmlLinks(_ html: String) -> [(String, String)] {
        let pattern = Regex(#"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#, [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        return pattern.re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m in
            let href = entities(ns.substring(with: m.range(at: 1))).trimmed
            let text = htmlToText(ns.substring(with: m.range(at: 2))).replacingOccurrences(of: "\n", with: " ").trimmed
            return (text, href)
        }
    }

    public static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<(script|style|head)\b.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|table|td)>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        s = entities(s)
        let lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t ]+"#, with: " ", options: .regularExpression).trimmed
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func entities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&zwnj;": "", "&zwj;": "", "&shy;": ""]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        let numeric = Regex(#"&#(x?)([0-9a-fA-F]+);"#, [])
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in numeric.re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = m.range(at: 1).length > 0
            if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(v) {
                result.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

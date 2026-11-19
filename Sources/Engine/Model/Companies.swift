import Foundation

/// Company names compared the way people mean them, for the list of companies to leave alone.
public enum CompanyName {
    /// Words that only say what kind of company it is ("Inc.", "Limited", "Group"), dropped from the end of a name.
    static let kindWords: Set<String> = [
        "inc", "incorporated", "llc", "ltd", "limited", "corp", "corporation", "co", "company", "plc", "gmbh", "ag", "sa",
        "nv", "bv", "pvt", "private", "pte", "lp", "llp", "group", "holdings", "holding",
    ]

    /// The words of a company's name without what only says what kind of company it is: "The Coca-Cola Company" →
    /// ["coca", "cola"], "BeaconFire Inc." → ["beaconfire"], "AT&T" → ["att"], "Johnson & Johnson" → ["johnson", "and",
    /// "johnson"], "Dassault Systèmes" → ["dassault", "systemes"], "Amazon.com, Inc." → ["amazon"].
    public static func words(_ name: String) -> [String] {
        var words = split(name, brackets: false)
        if words.count > 1, words[0] == "the" { words.removeFirst() }
        while words.count > 1, let last = words.last, kindWords.contains(last) { words.removeLast() }
        return words
    }

    /// Lower-case words without accents, in one pass (the directory reads some 200,000 names): "&" or "+" between
    /// spaces is "and" and inside a word ("AT&T") nothing, like "." and "'" ("U.S.", "Macy's"); a web address's
    /// ending (".com") ends the word; without `brackets`, what's in brackets is left out.
    static func split(_ name: String, brackets: Bool) -> [String] {
        let folded = Array(name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: posix).lowercased().unicodeScalars)
        var words: [String] = [], word = String.UnicodeScalarView(), depth = 0, i = 0
        func end() { if !word.isEmpty { words.append(String(word)); word = String.UnicodeScalarView() } }
        while i < folded.count {
            let c = folded[i]
            if !brackets, c == "(" || c == "[" { depth += 1; end(); i += 1; continue }
            if !brackets, c == ")" || c == "]" { depth = max(0, depth - 1); end(); i += 1; continue }
            if depth > 0 { i += 1; continue }
            if CharacterSet.alphanumerics.contains(c) {
                word.append(c)
            } else if c == "&" || c == "+" {
                let spaced = (i == 0 || folded[i - 1] == " ") && (i + 1 == folded.count || folded[i + 1] == " ")
                if spaced { end(); words.append("and") }
            } else if c == "." {
                // ".com", ".io", ".ai"… at the end of a word: a web address, not part of the name.
                var j = i + 1, tail = ""
                while j < folded.count, CharacterSet.lowercaseLetters.contains(folded[j]) { tail.unicodeScalars.append(folded[j]); j += 1 }
                if domainEnds.contains(tail), j == folded.count || !CharacterSet.alphanumerics.contains(folded[j]) { end(); i = j; continue }
            } else if c != "'" && c != "’" {
                end()
            }
            i += 1
        }
        end()
        return words
    }

    static let posix = Locale(identifier: "en_US_POSIX")
    static let domainEnds: Set<String> = ["com", "io", "ai", "co", "net", "org"]

    /// The ways a name on a job card writes the company: the name, and a short name in brackets after it ("Amazon Web
    /// Services (AWS)" is also "AWS").
    static func forms(_ name: String) -> [[String]] {
        var out = [words(name)]
        if let r = name.range(of: #"\(([^)]{2,40})\)"#, options: .regularExpression) {
            let inner = words(String(name[r]).trimmingCharacters(in: CharacterSet(charactersIn: "()")))
            if !inner.isEmpty, inner.joined().count >= 2 { out.append(inner) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Whether the name `entry` (from the list) covers `company` (on a job): the same name however it's written
    /// ("BeaconFire" and "BeaconFire Inc.", "JPMorganChase" and "JPMorgan Chase"), or a longer name that starts with all
    /// of its words ("Tata" and "Tata Consultancy Services"; not "Meta" and "Metaview").
    static func covers(_ entry: [String], _ company: [String]) -> Bool {
        guard !entry.isEmpty, !company.isEmpty else { return false }
        return company.starts(with: entry) || company.joined() == entry.joined()
    }

    /// Words of what someone typed to search, as they typed them ("Tata Consulting" → ["tata", "consulting"]).
    static func searchWords(_ text: String) -> [String] { split(text, brackets: true) }
}

/// Large employers and the other names each goes by (from Wikidata, which is free to reuse: CC0), so a list that says
/// "Tata Consultancy Services" also skips a job from "TCS", and a search for "Tata Consulting" finds it. Bundled with
/// the app (Resources/Companies.tsv, built by scripts/make_companies.py): searching it never leaves the Mac.
public final class CompanyDirectory: Sendable {
    public struct Company: Sendable, Hashable {
        public let name: String
        public let otherNames: [String]
        /// About how many people work there (0 when unknown).
        public let employees: Int
        /// The company that owns it, as an index into `companies`.
        public let owner: Int?
    }

    public let companies: [Company]
    /// Each company's names as words (`CompanyName.words`), its main name first.
    private let nameWords: [[[String]]]
    /// Which of each company's other names are its own (bit k for otherNames[k]): not one another company also goes
    /// by, unless this one is far bigger ("TCS" is Tata Consultancy Services' though a bank also goes by it; "SAIC" isn't
    /// Leidos's, which went by it before SAIC was a company of its own).
    private let ownNames: [UInt16]
    /// Each main name's words run together → the companies named so, biggest first.
    private let byName: [String: [Int32]]
    /// Each other name's words run together → the company it's the own name of.
    private let byOtherName: [String: Int32]
    /// The first two letters of each word of each name → the companies (for searching).
    private let byStart: [String: [Int32]]
    /// A company → the companies it owns.
    private let owns: [Int32: [Int32]]

    public static let shared = CompanyDirectory(contentsOf: defaultFile)

    /// The app's copy, or (in tests and development builds) the repository's.
    static var defaultFile: URL? {
        if let inApp = Bundle.main.url(forResource: "Companies", withExtension: "tsv") { return inApp }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repo.appendingPathComponent("Resources/Companies.tsv")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
        #else
        return nil
        #endif
    }

    convenience init(contentsOf url: URL?) {
        self.init(tsv: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }

    /// Lines of name, other names (split by "|"), staff, and the owner's line number (from 0), split by tabs.
    public init(tsv: String) {
        var list: [Company] = []
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), !name.isEmpty else { continue }
            let others = parts.count > 1 ? parts[1].split(separator: "|").map(String.init) : []
            let staff = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            let owner = parts.count > 3 ? Int(parts[3]) : nil
            list.append(Company(name: name, otherNames: others, employees: staff, owner: owner))
        }
        companies = list
        var nameWords: [[[String]]] = [], byName: [String: [Int32]] = [:], holders: [String: [Int32]] = [:]
        var byStart: [String: [Int32]] = [:], owns: [Int32: [Int32]] = [:]
        nameWords.reserveCapacity(list.count)
        for (i, c) in list.enumerated() {
            let n = Int32(i)
            let all = ([c.name] + c.otherNames).map(CompanyName.words)
            nameWords.append(all)
            var starts = Set<String>(), keys = Set<String>()
            for (k, w) in all.enumerated() where !w.isEmpty {
                if k == 0 { byName[w.joined(), default: []].append(n) }
                if keys.insert(w.joined()).inserted { holders[w.joined(), default: []].append(n) }
                for word in w where word.count >= 2 { starts.insert(String(word.prefix(2))) }
            }
            for s in starts { byStart[s, default: []].append(n) }
            if let o = c.owner, o >= 0, o < list.count, o != i { owns[Int32(o), default: []].append(n) }
        }
        // A name several companies go by belongs to the one far bigger than the rest, else to none of them.
        func owner(_ h: [Int32]) -> Int32? {
            guard h.count > 1 else { return h.first }
            let bySize = h.sorted { list[Int($0)].employees > list[Int($1)].employees }
            let first = list[Int(bySize[0])].employees, second = list[Int(bySize[1])].employees
            return first >= 5 * max(second, 1000) ? bySize[0] : nil  // a company without a staff count could be any size
        }
        var ownNames = [UInt16](repeating: 0, count: list.count), byOtherName: [String: Int32] = [:]
        for (i, all) in nameWords.enumerated() {
            for (k, w) in all.enumerated() where k > 0 && k <= 16 && !w.isEmpty {
                guard let h = holders[w.joined()], owner(h) == Int32(i) else { continue }
                ownNames[i] |= 1 << (k - 1)
                if byName[w.joined()] == nil { byOtherName[w.joined()] = Int32(i) }
            }
        }
        self.nameWords = nameWords
        self.ownNames = ownNames
        self.byName = byName
        self.byOtherName = byOtherName
        self.byStart = byStart
        self.owns = owns
    }

    /// The company a name means: the one whose main name it is, else the biggest that also goes by it.
    public func company(named name: String) -> Int? { best(CompanyName.words(name)) }

    func best(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        if let main = byName[words.joined()]?.first { return Int(main) }
        return byOtherName[words.joined()].map(Int.init)
    }

    /// The names the company goes by, as words: its main name and its own other names.
    func names(_ i: Int) -> [[String]] {
        nameWords[i].enumerated().filter { k, w in !w.isEmpty && (k == 0 || (k <= 16 && ownNames[i] & (1 << (k - 1)) != 0)) }.map(\.element)
    }

    // MARK: the list of companies to leave alone

    /// The entry on `list` that covers a job's `company`, if any: the same company under any of its names (TCS for
    /// Tata Consultancy Services), or a company whose name starts with the entry ("Tata" covers "Tata Steel").
    public func listed(_ company: String, in list: [String]) -> String? {
        let own = CompanyName.forms(company)
        guard !own.isEmpty else { return nil }
        var mine = own
        for form in own { if let c = best(form) { mine += names(c) } }
        for entry in list {
            let words = CompanyName.words(entry)
            guard !words.isEmpty else { continue }
            var theirs = [words]
            if let c = best(words) { theirs += names(c) }
            if mine.contains(where: { m in theirs.contains { CompanyName.covers($0, m) } }) { return entry }
        }
        return nil
    }

    /// The other names a list entry also skips ("TCS" for "Tata Consultancy Services"), for showing beside it.
    public func otherNames(of entry: String) -> [String] {
        guard let c = company(named: entry) else { return [] }
        let mine = CompanyName.words(entry)
        var seen: Set<String> = [mine.joined()]
        let own = companies[c].otherNames.enumerated().filter { k, _ in k < 16 && ownNames[c] & (1 << k) != 0 }.map(\.element)
        return ([companies[c].name] + own).filter { seen.insert(CompanyName.words($0).joined()).inserted }
    }

    // MARK: searching

    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var id: String { name }
        /// The name to put on the list.
        public let name: String
        /// What tells it apart: its other names, its size, who owns it, how many of the person's jobs it posted.
        public let detail: String
    }

    public struct Search: Sendable {
        public var suggestions: [Suggestion] = []
        /// Known companies whose names start with what was typed (put on the list as typed, it skips all of them).
        public var startingWith = 0
        /// A few of them, biggest first.
        public var examples: [String] = []
        public init() {}
    }

    /// Companies for what someone is typing: the company itself under any of its names, others with those words,
    /// and the companies those own. `seen` is the companies of the person's own jobs (LinkedIn's names) and how many
    /// jobs each posted: they come first, under the name LinkedIn shows.
    public func search(_ text: String, seen: [String: Int] = [:], limit: Int = 8) -> Search {
        let query = CompanyName.searchWords(text)
        guard let longest = query.filter({ !CompanyName.kindWords.contains($0) }).max(by: { $0.count < $1.count }), longest.count >= 2 else { return Search() }
        let typed = CompanyName.words(text)

        struct Hit { var score: Double; var name: String; var detail: String; var key: String }
        var hits: [Hit] = []
        var taken = Set<String>()
        var startingWith = 0, examples: [String] = []

        // The person's own jobs' companies, as LinkedIn names them.
        var seenByCompany: [Int: (String, Int)] = [:]
        for (name, count) in seen {
            let w = CompanyName.words(name)
            guard !w.isEmpty else { continue }
            if CompanyName.covers(typed, w) { startingWith += 1; if examples.count < 3 { examples.append(name) } }
            if let c = best(w), seenByCompany[c].map({ $0.1 < count }) ?? true { seenByCompany[c] = (name, count) }
            guard let m = Self.match(query, w) else { continue }
            let c = best(w)
            let detail = [count == 1 ? "In 1 of your jobs" : "In \(count) of your jobs", c.map { describe($0, shownAs: name) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            hits.append(Hit(score: m * 100 + 90 + Double(min(count, 20)) * 2 + (c.map { size($0) } ?? 0), name: name, detail: detail, key: w.joined()))
            taken.insert(w.joined())
            if let c { taken.insert(CompanyName.words(companies[c].name).joined()) }
        }

        // The directory.
        var scored: [(Int, Double, String)] = []
        for n in byStart[String(longest.prefix(2))] ?? [] {
            let i = Int(n), c = companies[i]
            var bestScore = 0.0, via = ""
            for (k, w) in nameWords[i].enumerated() {
                guard let m = Self.match(query, w) else { continue }
                let s = m - (k == 0 ? 0 : 0.5)
                if s > bestScore { bestScore = s; via = k == 0 ? "" : c.otherNames[k - 1] }
            }
            guard bestScore > 0 else { continue }
            if CompanyName.covers(typed, nameWords[i][0]), seenByCompany[i] == nil {
                startingWith += 1
                if examples.count < 3 { examples.append(c.name) }
            }
            scored.append((i, bestScore * 100 + size(i), via))
        }
        scored.sort { $0.1 > $1.1 }
        for (i, score, via) in scored.prefix(limit * 3) {
            let key = CompanyName.words(companies[i].name).joined()
            guard !taken.contains(key) else { continue }
            taken.insert(key)
            hits.append(Hit(score: score, name: companies[i].name, detail: describe(i, shownAs: companies[i].name, via: via), key: key))
        }
        // What the best few own, under their own names (Tata Motors owns Jaguar Land Rover).
        for (i, score, _) in scored.prefix(3) {
            for o in (owns[Int32(i)] ?? []).prefix(4) {
                let key = CompanyName.words(companies[Int(o)].name).joined()
                guard !taken.contains(key) else { continue }
                taken.insert(key)
                hits.append(Hit(score: score - 30, name: companies[Int(o)].name, detail: describe(Int(o), shownAs: companies[Int(o)].name), key: key))
            }
        }
        hits.sort { $0.score > $1.score }
        var out = Search()
        out.suggestions = hits.prefix(limit).map { Suggestion(name: $0.name, detail: $0.detail) }
        out.startingWith = startingWith
        out.examples = examples
        return out
    }

    /// How well the typed words fit a name's words (0 when one of them fits none): each typed word is a word of the
    /// name (3), starts one (2), or shares most of its start with one ("consulting" and "consultancy": 1); more if the
    /// name starts with the first typed word, and with no words besides.
    static func match(_ query: [String], _ name: [String]) -> Double? {
        guard !query.isEmpty, !name.isEmpty else { return nil }
        var total = 0.0, counted = 0
        for (n, q) in query.enumerated() {
            var bestFit = 0.0
            for w in name {
                if w == q { bestFit = 3; break }
                if w.hasPrefix(q) { bestFit = max(bestFit, 2); continue }
                let common = zip(w, q).prefix { $0 == $1 }.count
                if common >= 5, Double(common) >= 0.7 * Double(q.count) { bestFit = max(bestFit, 1) }
            }
            // "Inc", "Limited", "The": names are kept without them.
            if bestFit == 0, CompanyName.kindWords.contains(q) || (n == 0 && q == "the") { continue }
            guard bestFit > 0 else { return nil }
            total += bestFit
            counted += 1
        }
        guard counted > 0 else { return nil }
        if let first = query.first(where: { !CompanyName.kindWords.contains($0) && $0 != "the" }), name[0].hasPrefix(first) { total += 2 }
        if name.count == counted, total >= Double(3 * counted) { total += 3 }
        return total / Double(counted) - 0.05 * Double(max(0, name.count - counted))
    }

    /// Among names that fit as well, bigger employers first (Tata Consultancy Services, 600,000 people, over Tata Steel).
    private func size(_ i: Int) -> Double { log10(Double(max(companies[i].employees, 0)) + 10) * 10 }

    /// "Also TCS · 600,000 people · Part of Tata Sons".
    private func describe(_ i: Int, shownAs: String, via: String = "") -> String {
        let c = companies[i]
        let shown = CompanyName.words(shownAs).joined()
        var parts: [String] = []
        var others = ([c.name] + c.otherNames).filter { ($0.count <= 30 || $0 == via) && CompanyName.words($0).joined() != shown }
        if !via.isEmpty, let at = others.firstIndex(of: via) { others.insert(others.remove(at: at), at: 0) }
        var said = Set<String>()
        others = others.filter { said.insert(CompanyName.words($0).joined()).inserted }
        if !others.isEmpty { parts.append("Also " + others.prefix(2).joined(separator: ", ")) }
        if c.employees >= 1000 { parts.append(c.employees.formatted(.number.notation(.compactName)) + " people") }
        if let o = c.owner, o < companies.count { parts.append("Part of " + companies[o].name) }
        return parts.joined(separator: " · ")
    }
}

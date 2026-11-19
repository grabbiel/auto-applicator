import Foundation

public struct JobCard: Sendable, Equatable {
    public var id: String
    public var title: String
    public var company: String
    public var location: String
    public var applied: Bool

    public init(id: String, title: String, company: String, location: String, applied: Bool) {
        self.id = id
        self.title = title
        self.company = company
        self.location = location
        self.applied = applied
    }

    public var url: URL { URL(string: "https://www.linkedin.com/jobs/view/\(id)/")! }
}

/// LinkedIn job search: the search address, the result cards, and each job's page.
public enum LinkedIn {
    public static let home = URL(string: "https://www.linkedin.com/")!
    public static let feed = URL(string: "https://www.linkedin.com/feed/")!
    public static let login = URL(string: "https://www.linkedin.com/login")!
    static let pageSize = 25

    /// `geoId` is LinkedIn's number for the place in `search.location`. Signed-in searches go by it and ignore the text
    /// alone, falling back to the location on the member's profile.
    public static func searchURL(keywords: String, search: SearchSettings, geoId: String? = nil, start: Int = 0) -> URL {
        var c = URLComponents(string: "https://www.linkedin.com/jobs/search/")!
        var q = [URLQueryItem(name: "keywords", value: keywords), URLQueryItem(name: "location", value: search.location)]
        if let geoId { q.append(URLQueryItem(name: "geoId", value: geoId)) }
        if !search.workplace.isEmpty { q.append(URLQueryItem(name: "f_WT", value: search.workplace.map(\.linkedInCode).joined(separator: ","))) }
        if !search.levels.isEmpty { q.append(URLQueryItem(name: "f_E", value: search.levels.map(\.linkedInCode).joined(separator: ","))) }
        if let tpr = search.datePosted.linkedInCode { q.append(URLQueryItem(name: "f_TPR", value: tpr)) }
        if !search.includeExternal { q.append(URLQueryItem(name: "f_AL", value: "true")) }
        q.append(URLQueryItem(name: "sortBy", value: "DD"))
        if start > 0 { q.append(URLQueryItem(name: "start", value: String(start))) }
        c.queryItems = q
        return c.url!
    }

    /// Places LinkedIn's lookup isn't needed for.
    static let knownPlaces = ["united states": "103644278", "united states of america": "103644278", "usa": "103644278", "us": "103644278",
                              "estados unidos": "103644278"]

    static let usStates = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado", "CT": "Connecticut",
        "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois",
        "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York",
        "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah",
        "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    ]

    /// What to ask LinkedIn's place lookup for `location`, best first: "Austin, TX" → "Austin, TX", "Austin, Texas",
    /// "Austin" (it finds nothing for state abbreviations).
    static func placeQueries(_ location: String) -> [String] {
        let place = location.trimmed
        guard !place.isEmpty else { return [] }
        var out = [place]
        let parts = place.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        if parts.count >= 2, let state = usStates[parts[1].uppercased()] {
            out.append(([parts[0], state] + parts.dropFirst(2)).joined(separator: ", "))
        }
        if parts.count >= 2 { out.append(parts[0]) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Why a job is skipped by the user's filters (nil: keep it).
    public static func filterReason(_ card: JobCard, _ filters: Filters) -> JobStatus? {
        // The company under any of its names, or one whose name starts with what's on the list ("Tata" skips "Tata
        // Consultancy Services", "BeaconFire" skips "BeaconFire Inc.").
        if !card.company.trimmed.isEmpty, !filters.blacklistCompanies.isEmpty,
           CompanyDirectory.shared.listed(card.company, in: filters.blacklistCompanies) != nil { return .skippedBlacklist }
        let title = card.title.lowercased()
        if filters.titleExclude.contains(where: { !$0.trimmed.isEmpty && title.contains($0.trimmed.lowercased()) }) { return .skippedTitleFilter }
        let must = filters.titleMustContain.map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        if !must.isEmpty && !must.contains(where: title.contains) { return .skippedTitleFilter }
        return nil
    }

    /// Whether a job fits the search's workplace and level choices. LinkedIn's AI results page ignores both, so they're
    /// checked here: the workplace from the "(Remote)", "(Hybrid)" or "(On-site)" after the place (jobs without one pass),
    /// and, when only early-career levels are chosen, titles that say they're senior.
    public static func fits(_ card: JobCard, _ search: SearchSettings) -> Bool {
        if let workplace = workplace(of: card.location), !search.workplace.isEmpty, !search.workplace.contains(workplace) { return false }
        let early: Set<ExperienceLevel> = [.internship, .entry, .associate]
        if !search.levels.isEmpty, Set(search.levels).isSubset(of: early),
           card.title.range(of: seniorTitle, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    /// Senior titles ("Member of Technical Staff" is a title at any level).
    static let seniorTitle = #"\b(senior|sr\.?|(?<!technical )staff|principal|lead|manager|director|head of|vp|vice president|architect|distinguished|fellow|iii|iv)\b"#

    /// The workplace a job's place names: "Austin, TX (Hybrid)" → hybrid; nil when it doesn't say.
    static func workplace(of location: String) -> WorkplaceType? {
        let place = location.trimmed.lowercased()
        if place == "remote" || place == "en remoto" { return .remote }
        guard let open = place.lastIndex(of: "("), place.hasSuffix(")") else { return nil }
        switch place[place.index(after: open)..<place.index(before: place.endIndex)] {
        case "remote", "en remoto", "remoto": return .remote
        case "hybrid", "híbrido": return .hybrid
        case "on-site", "on site", "presencial": return .onSite
        default: return nil
        }
    }

    static func cards(from raw: Any?) -> [JobCard] {
        ((raw as? [[String: Any]]) ?? []).compactMap { r in
            guard let id = r["job_id"] as? String else { return nil }
            return JobCard(id: id, title: (r["title"] as? String) ?? "", company: (r["company"] as? String) ?? "",
                           location: (r["location"] as? String) ?? "", applied: (r["applied"] as? Bool) ?? false)
        }
    }
}

extension WebAgent {
    /// Whether this browser is signed in to LinkedIn (opens the feed to check).
    public func linkedInSignedIn(load: Bool = true) async -> Bool {
        if await cookies(for: "linkedin.com").contains(where: { $0.name == "li_at" }) == false { return false }
        guard load else { return true }
        do { try await self.load(LinkedIn.feed) } catch { return false }
        try? await sleep(1)
        return await bool(Scripts.linkedInSignedIn)
    }

    /// LinkedIn's number for a place ("United States" → 103644278), from the lookup behind its own location box.
    /// Nil when LinkedIn doesn't know the place. Needs a LinkedIn page open (the lookup is on LinkedIn's site).
    func linkedInGeoId(for location: String) async -> String? {
        let place = location.trimmed
        if let id = LinkedIn.knownPlaces[place.lowercased()] { return id }
        for query in LinkedIn.placeQueries(place) {
            if let id = (try? await js(Scripts.linkedInPlace, ["query": query])) as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// One page of search results (25 jobs), scrolled so every card renders.
    func searchPage(keywords: String, search: SearchSettings, geoId: String?, page: Int) async throws -> [JobCard] {
        try await load(LinkedIn.searchURL(keywords: keywords, search: search, geoId: geoId, start: page * LinkedIn.pageSize))
        let found = await waitFor(Scripts.jobCardSelector, timeout: 15)
        // LinkedIn can end the session mid-run (it does when a sign-in moves far, e.g. to the cloud browser); its public
        // pages still list jobs, but Easy Apply and the filters need the sign-in.
        if await bool(Scripts.linkedInSignedOutPage) { throw RunError.signedOut }
        guard found else {
            let place = url.map { "\($0.host ?? "")\($0.path)" } ?? "?"
            let title = await string("return document.title")
            Log.info("No job cards on page \(page + 1) for \"\(keywords)\" (\(place): \(title))")
            return []
        }
        guard try await showResultsPage(page + 1) else {
            Log.info("No page \(page + 1) of results for \"\(keywords)\"")
            return []
        }
        _ = try? await js(Scripts.scrollJobList, ["step": 300])
        return LinkedIn.cards(from: try? await js(Scripts.jobCards))
    }

    /// LinkedIn's AI results page (where /jobs/search/ now leads) ignores `start` and pages with buttons: moves its pager to
    /// `page` (1-based). True once the page shows, false when there's no such page; true on the other layouts, where the
    /// address already chose the page.
    func showResultsPage(_ page: Int) async throws -> Bool {
        var now = ((try? await js(Scripts.resultsPage)) as? Int) ?? -1
        if now < 0 { return true }
        var clicks = 0
        while now < page {
            guard clicks < page + 2, await bool(Scripts.tagPagerButton, ["page": page]) else { return false }
            clicks += 1
            let first = await string(Scripts.firstResult)
            guard await click("[data-auto-page]") else { return false }
            // The list redraws in place: wait for the pager to move on and the cards to change.
            let deadline = Date().addingTimeInterval(15)
            var moved = false
            while Date() < deadline, !moved {
                try await sleep(0.3)
                let shown = ((try? await js(Scripts.resultsPage)) as? Int) ?? -1
                let top = await string(Scripts.firstResult)
                if shown > now, !top.isEmpty, top != first { now = shown; moved = true }
            }
            guard moved else { return false }
        }
        try await sleep(0.5)
        return now == page
    }

    struct JobDetails {
        enum Kind: String { case easyApply = "easy_apply", external, applied, closed, unknown }
        var kind: Kind
        var description: String
    }

    func openJob(_ card: JobCard) async throws -> JobDetails {
        try await load(card.url)
        await waitFor("main", timeout: 15)
        try await sleep(1.5)
        if await bool(Scripts.linkedInSignedOutPage) { throw RunError.signedOut }
        return try await readJobDetails()
    }

    /// The job page's description and apply button (which renders a moment after the page).
    func readJobDetails(attempts: Int = 6) async throws -> JobDetails {
        var r: [String: Any] = [:]
        for i in 0..<attempts {
            r = ((try? await js(Scripts.jobDetails)) as? [String: Any]) ?? [:]
            if let k = r["kind"] as? String, k != "unknown" { break }
            if i < attempts - 1 { try await sleep(0.7) }
        }
        return JobDetails(kind: JobDetails.Kind(rawValue: (r["kind"] as? String) ?? "unknown") ?? .unknown,
                          description: (r["description"] as? String) ?? "")
    }

    /// Presses a job's external "Apply" button and waits for the company's page (it may open as a new window,
    /// which this view loads itself, or after a "Continue" dialog).
    func openExternalApplication(timeout: TimeInterval = 20) async throws {
        let start = url
        await click(#"[data-auto-apply="1"]"#)
        func left() -> Bool { url?.host?.contains("linkedin.com") == false || (url != start && url?.path.contains("/jobs/view/") == false) }
        var waited = 0.0
        while waited < 8, !left() { try await sleep(0.25); waited += 0.25 }
        // A dialog first: "Continue to apply", or the "Job search safety reminder" with "Continue applying" (not always
        // marked as a dialog, so last the whole page, for that wording only).
        let inDialog = #"^(continue|apply|continue to apply|continue applying|apply on company (site|website)|go to (the )?(company )?(site|website)|continuar|continuar con la solicitud|seguir solicitando|solicitar)$"#
        for (pattern, root) in [(inDialog, "[role=dialog]"), (inDialog, "dialog[open]"), (inDialog, "[aria-modal=true]"), (inDialog, ".artdeco-modal"),
                                (#"^(continue applying|continue to apply|seguir solicitando)$"#, nil)] as [(String, String?)] where !left() {
            guard await findButton(pattern, root: root) != nil else { continue }
            await clickFoundButton()
            waited = 0
            while waited < 8, !left() { try await sleep(0.25); waited += 0.25 }
            break
        }
        // Pressed, and LinkedIn says so ("Job moved to In progress under Clicked apply"), but no company page came
        // (Evident's, about once a run): once more.
        if !left(), await exists(#"[data-auto-apply="1"]"#) {
            Log.info("LinkedIn's Apply opened nothing; pressing it once more")
            await click(#"[data-auto-apply="1"]"#)
            waited = 0
            while waited < 10, !left() { try await sleep(0.25); waited += 0.25 }
        }
        guard left() else { throw BrowserError("The Apply button didn't open the company's site.") }
        try await waitForRedirects(timeout: timeout)
    }

    /// Waits until the address stops changing (tracking redirects) and the page has loaded.
    func waitForRedirects(timeout: TimeInterval = 20, stable: TimeInterval = 1.5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = url, since = Date()
        while Date() < deadline {
            try await sleep(0.25)
            if url != last { last = url; since = Date() } else if Date().timeIntervalSince(since) >= stable, url?.absoluteString != "about:blank" { break }
        }
        try? await waitForLoad(timeout: 10)
    }
}

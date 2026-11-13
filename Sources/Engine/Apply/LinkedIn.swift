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

    public static func searchURL(keywords: String, search: SearchSettings, start: Int = 0) -> URL {
        var c = URLComponents(string: "https://www.linkedin.com/jobs/search/")!
        var q = [URLQueryItem(name: "keywords", value: keywords), URLQueryItem(name: "location", value: search.location)]
        if !search.workplace.isEmpty { q.append(URLQueryItem(name: "f_WT", value: search.workplace.map(\.linkedInCode).joined(separator: ","))) }
        if !search.levels.isEmpty { q.append(URLQueryItem(name: "f_E", value: search.levels.map(\.linkedInCode).joined(separator: ","))) }
        if let tpr = search.datePosted.linkedInCode { q.append(URLQueryItem(name: "f_TPR", value: tpr)) }
        if !search.includeExternal { q.append(URLQueryItem(name: "f_AL", value: "true")) }
        q.append(URLQueryItem(name: "sortBy", value: "DD"))
        if start > 0 { q.append(URLQueryItem(name: "start", value: String(start))) }
        c.queryItems = q
        return c.url!
    }

    /// Why a job is skipped by the user's filters (nil: keep it).
    public static func filterReason(_ card: JobCard, _ filters: Filters) -> JobStatus? {
        let company = card.company.trimmed.lowercased()
        if !company.isEmpty && filters.blacklistCompanies.contains(where: { $0.trimmed.lowercased() == company }) { return .skippedBlacklist }
        let title = card.title.lowercased()
        if filters.titleExclude.contains(where: { !$0.trimmed.isEmpty && title.contains($0.trimmed.lowercased()) }) { return .skippedTitleFilter }
        let must = filters.titleMustContain.map { $0.trimmed.lowercased() }.filter { !$0.isEmpty }
        if !must.isEmpty && !must.contains(where: title.contains) { return .skippedTitleFilter }
        return nil
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

    /// One page of search results (25 jobs), scrolled so every card renders.
    func searchPage(keywords: String, search: SearchSettings, page: Int) async throws -> [JobCard] {
        try await load(LinkedIn.searchURL(keywords: keywords, search: search, start: page * LinkedIn.pageSize))
        guard await waitFor("[data-occludable-job-id], [data-job-id]", timeout: 15) else {
            Log.info("No job cards on page \(page + 1) for \"\(keywords)\"")
            return []
        }
        _ = try? await js(Scripts.scrollJobList, ["step": 300])
        return LinkedIn.cards(from: try? await js(Scripts.jobCards))
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
        if !left(), await findButton(#"^(continue|apply|continue to apply)$"#, root: "[role=dialog]") != nil {
            await clickFoundButton()
            waited = 0
            while waited < 8, !left() { try await sleep(0.25); waited += 0.25 }
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

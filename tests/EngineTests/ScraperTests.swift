import XCTest
@testable import Engine

final class ScraperTests: XCTestCase {
    func testSearchURLEasyApplyOnly() {
        var s = SearchSettings()
        s.location = "Austin, TX"
        s.workplace = [.remote, .hybrid]
        s.levels = [.associate, .midSenior]
        s.datePosted = .past24h
        let url = LinkedIn.searchURL(keywords: "Data Engineer", search: s, start: 25)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://www.linkedin.com/jobs/search/?"))
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items, ["keywords": "Data Engineer", "location": "Austin, TX", "f_WT": "2,3", "f_E": "3,4", "f_TPR": "r86400",
                               "f_AL": "true", "sortBy": "DD", "start": "25"])
    }

    func testSearchURLWithCompanySites() {
        var s = SearchSettings()
        s.includeExternal = true
        s.datePosted = .any
        let names = URLComponents(url: LinkedIn.searchURL(keywords: "x", search: s), resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)
        XCTAssertFalse(names.contains("f_AL"))
        XCTAssertFalse(names.contains("f_TPR"))
        XCTAssertFalse(names.contains("start"))
    }

    func testSearchURLCarriesThePlace() {
        let url = LinkedIn.searchURL(keywords: "iOS Engineer", search: SearchSettings(), geoId: "103644278")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["location"], "United States")
        XCTAssertEqual(items["geoId"], "103644278")
    }

    func testPlaceLookups() {
        XCTAssertEqual(LinkedIn.placeQueries("Austin, TX"), ["Austin, TX", "Austin, Texas", "Austin"])
        XCTAssertEqual(LinkedIn.placeQueries(" Lima, Peru "), ["Lima, Peru", "Lima"])
        XCTAssertEqual(LinkedIn.placeQueries("Germany"), ["Germany"])
        XCTAssertEqual(LinkedIn.placeQueries("  "), [])
        XCTAssertEqual(LinkedIn.knownPlaces["united states"], "103644278")
    }

    /// LinkedIn's AI results page ignores the workplace and level filters, so the run checks them on each card.
    func testWorkplaceAndLevelFit() {
        var search = SearchSettings()
        search.workplace = [.onSite, .hybrid]
        search.levels = [.associate, .entry]
        func card(_ title: String, _ location: String) -> JobCard { JobCard(id: "1", title: title, company: "Acme", location: location, applied: false) }
        XCTAssertTrue(LinkedIn.fits(card("Software Engineer", "Austin, TX (Hybrid)"), search))
        XCTAssertTrue(LinkedIn.fits(card("Software Engineer", "Highlands Ranch, CO (On-site)"), search))
        XCTAssertTrue(LinkedIn.fits(card("Software Engineer", "Tampa, FL"), search))  // doesn't say: kept
        XCTAssertFalse(LinkedIn.fits(card("Software Engineer", "United States (Remote)"), search))
        XCTAssertFalse(LinkedIn.fits(card("Senior Software Engineer", "Austin, TX (Hybrid)"), search))
        XCTAssertFalse(LinkedIn.fits(card("Sr. iOS Engineer", "Austin, TX"), search))
        XCTAssertFalse(LinkedIn.fits(card("Software Engineer III", "Austin, TX"), search))
        XCTAssertFalse(LinkedIn.fits(card("Engineering Manager", "Austin, TX"), search))
        XCTAssertTrue(LinkedIn.fits(card("Leadership Development Engineer", "Austin, TX"), search))
        XCTAssertTrue(LinkedIn.fits(card("Mobile Engineer (Member of Technical Staff)", "San Francisco, CA (On-site)"), search))
        XCTAssertFalse(LinkedIn.fits(card("Staff iOS Developer Experience Engineer - Slack", "Bellevue, WA (Hybrid)"), search))
        XCTAssertTrue(LinkedIn.fits(card("Associate Software Engineer – Full Stack", "Houston, TX (Hybrid)"), search))

        search.levels = [.entry, .midSenior]  // senior titles are wanted now
        XCTAssertTrue(LinkedIn.fits(card("Senior Software Engineer", "Austin, TX"), search))
        search.workplace = []
        XCTAssertTrue(LinkedIn.fits(card("Software Engineer", "United States (Remote)"), search))
        XCTAssertEqual(LinkedIn.workplace(of: "Remote"), .remote)
        XCTAssertEqual(LinkedIn.workplace(of: "Lima, Perú (Híbrido)"), .hybrid)
        XCTAssertNil(LinkedIn.workplace(of: "New York City Metropolitan Area"))
    }

    func testFilters() {
        let f = Filters(blacklistCompanies: ["BadCorp"], titleMustContain: ["engineer"], titleExclude: ["Manager"])
        func card(_ title: String, _ company: String = "Good") -> JobCard { JobCard(id: "1", title: title, company: company, location: "Remote", applied: false) }
        XCTAssertEqual(LinkedIn.filterReason(card("Data Engineer", "badcorp"), f), .skippedBlacklist)
        XCTAssertEqual(LinkedIn.filterReason(card("Engineering Manager"), f), .skippedTitleFilter)
        XCTAssertEqual(LinkedIn.filterReason(card("Data Scientist"), f), .skippedTitleFilter)
        XCTAssertNil(LinkedIn.filterReason(card("Senior Data Engineer"), f))
    }

    func testSiteDetection() {
        XCTAssertEqual(SiteRouter.detect(URL(string: "https://job-boards.greenhouse.io/initech/jobs/123")!), .greenhouse)
        XCTAssertEqual(SiteRouter.detect(URL(string: "https://initech.com/careers?gh_jid=123")!), .greenhouse)
        XCTAssertEqual(SiteRouter.detect(URL(string: "https://jobs.lever.co/initech/abc")!), .lever)
        XCTAssertEqual(SiteRouter.detect(URL(string: "https://jobs.ashbyhq.com/initech/abc")!), .ashby)
        XCTAssertEqual(SiteRouter.detect(URL(string: "https://initech.wd5.myworkdayjobs.com/en-US/careers/job/x")!), .workday)
        XCTAssertEqual(SiteRouter.detect(URL(string: "https://careers.initech.com/apply")!), .generic)
    }
}

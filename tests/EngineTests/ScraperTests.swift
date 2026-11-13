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

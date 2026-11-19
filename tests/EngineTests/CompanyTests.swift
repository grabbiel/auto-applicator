import XCTest
@testable import Engine

/// The list of companies to leave alone: a company is skipped under any of its names and with whatever follows its
/// name on a job card; searching finds it from part of a name, a short name or a near spelling.
final class CompanyTests: XCTestCase {
    // name, other names, staff, owner's line
    private let directory = CompanyDirectory(tsv: """
        Tata Consultancy Services\tTATA CONSULTANCY SERVICES LIMITED (Mumbai)|TCS\t600000\t5
        Ernst & Young\tEY|Ernst & Young Global Limited|Ernst and Young\t312250\t
        JPMorgan Chase\tJPMC\t271025\t
        Infosys limited\tInfosys Ltd|Infy\t200364\t
        Tata Steel\tTata Steel Limited\t80391\t5
        Tata Sons\t\t1000\t
        Jaguar Land Rover\tJLR\t40000\t7
        Tata Motors\t\t70000\t5
        Meta Platforms\tMeta|Facebook\t70000\t
        The Container Store\tTCS\t5000\t
        """)

    private func skips(_ company: String, _ list: [String]) -> Bool { directory.listed(company, in: list) != nil }

    func testNamesAreComparedWithoutWhatOnlySaysWhatKindOfCompanyItIs() {
        XCTAssertEqual(CompanyName.words("BeaconFire Inc."), ["beaconfire"])
        XCTAssertEqual(CompanyName.words("The Coca-Cola Company"), ["coca", "cola"])
        XCTAssertEqual(CompanyName.words("AT&T"), ["att"])
        XCTAssertEqual(CompanyName.words("Johnson & Johnson"), ["johnson", "and", "johnson"])
        XCTAssertEqual(CompanyName.words("Dassault Systèmes"), ["dassault", "systemes"])
        XCTAssertEqual(CompanyName.words("Amazon.com, Inc."), ["amazon"])
        XCTAssertEqual(CompanyName.words("U.S. Bank"), ["us", "bank"])
        XCTAssertEqual(CompanyName.words("Tata Consultancy Services Private Limited"), ["tata", "consultancy", "services"])
        XCTAssertEqual(CompanyName.words("Tata Consultancy Services (TCS)"), ["tata", "consultancy", "services"])
        XCTAssertEqual(CompanyName.words("Group"), ["group"], "a name that is only such a word stays")
    }

    func testAListedCompanyIsSkippedUnderAnyOfItsNames() {
        // What was on the list before: only the exact name was skipped, so "Tata" let Tata Consultancy Services through.
        XCTAssertTrue(skips("BeaconFire Inc.", ["BeaconFire"]))
        XCTAssertTrue(skips("Tata Consultancy Services", ["Tata"]))
        XCTAssertTrue(skips("Tata Steel", ["Tata"]))
        XCTAssertTrue(skips("TCS", ["Tata Consultancy Services"]), "its short name")
        XCTAssertTrue(skips("Tata Consultancy Services", ["TCS"]))
        XCTAssertTrue(skips("TATA CONSULTANCY SERVICES LIMITED", ["Tata Consultancy Services"]))
        XCTAssertTrue(skips("Ernst & Young LLP", ["EY"]))
        XCTAssertTrue(skips("EY-Parthenon", ["EY"]))
        XCTAssertTrue(skips("JPMorganChase", ["JPMorgan Chase"]), "LinkedIn runs the words together")
        XCTAssertTrue(skips("Facebook", ["Meta"]))
        XCTAssertTrue(skips("Amazon Web Services (AWS)", ["AWS"]), "a short name in brackets")
        XCTAssertTrue(skips("Infosys", ["Infosys Limited"]))

        XCTAssertFalse(skips("Metaview", ["Meta"]), "only whole words")
        XCTAssertFalse(skips("Eye Care Partners", ["EY"]))
        XCTAssertFalse(skips("Jaguar Land Rover", ["Tata"]), "what it owns has a name of its own; the search offers it")
        XCTAssertFalse(skips("Tata Consultancy Services", []))
        XCTAssertFalse(skips("", ["Tata"]))
        XCTAssertEqual(directory.company(named: "TCS"), 0, "a short name two companies share means the far bigger one")
        XCTAssertFalse(skips("TCS", ["The Container Store"]))
        XCTAssertTrue(skips("The Container Store", ["The Container Store"]))
    }

    func testAShortNameCompaniesOfASimilarSizeShareMeansNeither() {
        let shared = CompanyDirectory(tsv: """
            Leidos\tSAIC|Science Applications International\t47000\t
            Shanghai Automotive Industry\tSAIC|SAIC Motor\t200000\t
            SAIC Ventures\t\t300\t
            """)
        XCTAssertEqual(shared.company(named: "Science Applications International"), 0, "its own other name")
        XCTAssertNil(shared.company(named: "SAIC"))
        XCTAssertNotNil(shared.listed("Science Applications International", in: ["Leidos"]))
        XCTAssertNil(shared.listed("SAIC", in: ["Leidos"]), "SAIC could be either: not 47K vs 200K")
        XCTAssertNil(shared.listed("Leidos", in: ["SAIC Motor"]))
        XCTAssertNotNil(shared.listed("SAIC Ventures", in: ["SAIC Ventures"]))
        XCTAssertEqual(shared.otherNames(of: "Leidos"), ["Science Applications International"])
    }

    func testWithoutTheDirectoryNamesStillMatchHoweverTheyreWritten() {
        let none = CompanyDirectory(tsv: "")
        XCTAssertNotNil(none.listed("BeaconFire Inc.", in: ["BeaconFire"]))
        XCTAssertNotNil(none.listed("Tata Consultancy Services", in: ["Tata"]))
        XCTAssertNil(none.listed("TCS", in: ["Tata Consultancy Services"]))
    }

    func testSearchFindsTheCompanyFromPartOfANameAShortNameOrANearSpelling() {
        let consulting = directory.search("Tata Consulting").suggestions.map(\.name)
        XCTAssertEqual(consulting.first, "Tata Consultancy Services", "“consulting” is near “consultancy”")
        XCTAssertEqual(directory.search("tcs").suggestions.first?.name, "Tata Consultancy Services", "by its short name, the bigger first")
        XCTAssertTrue(directory.search("tcs").suggestions.contains { $0.name == "The Container Store" })

        let tata = directory.search("Tata")
        XCTAssertEqual(Set(tata.suggestions.prefix(4).map(\.name)), ["Tata Consultancy Services", "Tata Steel", "Tata Motors", "Tata Sons"])
        XCTAssertTrue(tata.suggestions.contains { $0.name == "Jaguar Land Rover" && $0.detail.contains("Part of Tata Motors") },
                      "what the companies found own, with their own names")
        XCTAssertEqual(tata.startingWith, 4, "put on the list as typed, “Tata” skips these four")
        XCTAssertEqual(tata.examples.first, "Tata Consultancy Services")

        let detail = directory.search("Tata Consultancy").suggestions.first?.detail ?? ""
        XCTAssertTrue(detail.contains("TCS"), detail)
        XCTAssertTrue(detail.contains("600K people"), detail)
        XCTAssertTrue(directory.search("t").suggestions.isEmpty, "one letter is too little to search")
        XCTAssertEqual(directory.search("Infosys Limited").suggestions.first?.name, "Infosys limited")
    }

    func testTheCompaniesOfThePersonsOwnJobsComeFirstUnderLinkedInsName() {
        let found = directory.search("tata", seen: ["Tata Consultancy Services": 15, "Tata Elxsi": 1])
        XCTAssertEqual(found.suggestions.first?.name, "Tata Consultancy Services")
        XCTAssertTrue(found.suggestions.first?.detail.hasPrefix("In 15 of your jobs") == true)
        XCTAssertTrue(found.suggestions.contains { $0.name == "Tata Elxsi" }, "a company the directory doesn't know")
        XCTAssertEqual(found.suggestions.filter { $0.name == "Tata Consultancy Services" }.count, 1)
        XCTAssertEqual(found.startingWith, 5)
    }

    func testOtherNamesShowWhatAnEntryAlsoSkips() {
        XCTAssertEqual(directory.otherNames(of: "TCS"), ["Tata Consultancy Services"], "once each, however it's written")
        XCTAssertEqual(directory.otherNames(of: "Tata Consultancy Services"), ["TCS"])
        XCTAssertEqual(directory.otherNames(of: "Nobody Inc."), [])
    }

    func testTheBundledDirectoryKnowsLargeEmployers() throws {
        let shared = CompanyDirectory.shared
        try XCTSkipIf(shared.companies.isEmpty, "Resources/Companies.tsv isn't there")
        XCTAssertGreaterThan(shared.companies.count, 20_000)
        XCTAssertNotNil(shared.listed("TCS", in: ["Tata Consultancy Services"]))
        XCTAssertNotNil(shared.listed("Infosys", in: ["Infosys Limited"]))
        XCTAssertEqual(shared.search("Tata Consulting").suggestions.first?.name, "Tata Consultancy Services")
        let started = Date()
        for q in ["Tata", "Deloitte", "Amazon", "Capital One", "Ernst", "a", "co"] { _ = shared.search(q) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "fast enough to search as someone types")
    }
}

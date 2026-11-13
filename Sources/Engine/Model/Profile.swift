import Foundation

public let declineToSelfIdentify = "Decline to self-identify"

/// Everything the app may say about the candidate. Stored as profile.json (snake_case keys, the same shape version 0.3
/// used in profile.yaml). Every field has a default so a partly filled file always loads.
public struct Profile: Codable, Equatable, Sendable {
    public var personal = Personal()
    public var workAuthorization = WorkAuthorization()
    public var compensation = Compensation()
    public var preferences = Preferences()
    public var summary = ""
    public var skills: [String] = []
    /// Years of hands-on experience per skill; "total" is the overall number.
    public var experienceYears: [String: Double] = [:]
    public var workHistory: [Role] = []
    public var education: [Education] = []
    public var certifications: [String] = []
    public var languages: [String] = ["English"]
    public var eeo = EEO()
    /// Question → answer pairs the user wants reused verbatim (matched by similar wording).
    public var extraAnswers: [String: String] = [:]
    public var files = Files()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case personal, summary, skills, education, certifications, languages, eeo, files, compensation, preferences
        case workAuthorization = "work_authorization", experienceYears = "experience_years", workHistory = "work_history"
        case extraAnswers = "extra_answers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        personal = try c.decodeIfPresent(Personal.self, forKey: .personal) ?? Personal()
        workAuthorization = try c.decodeIfPresent(WorkAuthorization.self, forKey: .workAuthorization) ?? WorkAuthorization()
        compensation = try c.decodeIfPresent(Compensation.self, forKey: .compensation) ?? Compensation()
        preferences = try c.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        experienceYears = try c.decodeIfPresent([String: Double].self, forKey: .experienceYears) ?? [:]
        workHistory = try c.decodeIfPresent([Role].self, forKey: .workHistory) ?? []
        education = try c.decodeIfPresent([Education].self, forKey: .education) ?? []
        certifications = try c.decodeIfPresent([String].self, forKey: .certifications) ?? []
        languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? ["English"]
        eeo = try c.decodeIfPresent(EEO.self, forKey: .eeo) ?? EEO()
        extraAnswers = try c.decodeIfPresent([String: String].self, forKey: .extraAnswers) ?? [:]
        files = try c.decodeIfPresent(Files.self, forKey: .files) ?? Files()
    }

    public var currentRole: Role? { workHistory.first(where: \.isCurrent) ?? workHistory.first }

    public var totalYears: Double? {
        for key in ["total", "overall", "professional"] { if let v = experienceYears[key] { return v } }
        return experienceYears.values.max()
    }

    /// Skill → years without the overall number, sorted by most years.
    public var skillYears: [(skill: String, years: Double)] {
        experienceYears.filter { !["total", "overall", "professional"].contains($0.key.lowercased()) }
            .map { ($0.key, $0.value) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    public var isComplete: Bool {
        !personal.firstName.trimmed.isEmpty && !personal.lastName.trimmed.isEmpty && personal.email.contains("@")
            && !personal.phone.trimmed.isEmpty
    }
}

public struct Personal: Codable, Equatable, Sendable {
    public var firstName = ""
    public var lastName = ""
    public var preferredName = ""
    public var email = ""
    public var phone = ""
    public var phoneCountryCode = "+1"
    public var address = Address()
    public var location = ""
    public var linkedin = ""
    public var github = ""
    public var portfolio = ""

    public init() {}
    public var fullName: String { "\(firstName) \(lastName)".trimmed }
    /// "Austin, TX" — the city and state, or the free-text location.
    public var displayLocation: String {
        let parts = [address.city, address.state].map(\.trimmed).filter { !$0.isEmpty }
        return parts.isEmpty ? location : parts.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case email, phone, address, location, linkedin, github, portfolio
        case firstName = "first_name", lastName = "last_name", preferredName = "preferred_name"
        case phoneCountryCode = "phone_country_code"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName) ?? ""
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName) ?? ""
        preferredName = try c.decodeIfPresent(String.self, forKey: .preferredName) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try c.decodeLenientString(forKey: .phone)
        phoneCountryCode = try c.decodeIfPresent(String.self, forKey: .phoneCountryCode) ?? "+1"
        address = try c.decodeIfPresent(Address.self, forKey: .address) ?? Address()
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        linkedin = try c.decodeIfPresent(String.self, forKey: .linkedin) ?? ""
        github = try c.decodeIfPresent(String.self, forKey: .github) ?? ""
        portfolio = try c.decodeIfPresent(String.self, forKey: .portfolio) ?? ""
    }
}

public struct Address: Codable, Equatable, Sendable {
    public var street = ""
    public var city = ""
    public var state = ""
    public var postalCode = ""
    public var country = "United States"

    public init() {}
    enum CodingKeys: String, CodingKey { case street, city, state, country, postalCode = "postal_code" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        street = try c.decodeIfPresent(String.self, forKey: .street) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        postalCode = try c.decodeLenientString(forKey: .postalCode)
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? "United States"
    }
}

public struct WorkAuthorization: Codable, Equatable, Sendable {
    public var authorizedToWork = true
    public var requiresSponsorship = false
    public var visaStatus = ""
    public var citizenship = ""
    public var securityClearance = "None"

    public init() {}
    enum CodingKeys: String, CodingKey {
        case citizenship
        case authorizedToWork = "authorized_to_work_us", requiresSponsorship = "requires_sponsorship"
        case visaStatus = "visa_status", securityClearance = "security_clearance"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authorizedToWork = try c.decodeIfPresent(Bool.self, forKey: .authorizedToWork) ?? true
        requiresSponsorship = try c.decodeIfPresent(Bool.self, forKey: .requiresSponsorship) ?? false
        visaStatus = try c.decodeIfPresent(String.self, forKey: .visaStatus) ?? ""
        citizenship = try c.decodeIfPresent(String.self, forKey: .citizenship) ?? ""
        securityClearance = try c.decodeIfPresent(String.self, forKey: .securityClearance) ?? "None"
    }
}

public struct Compensation: Codable, Equatable, Sendable {
    public var desiredBase: Int?
    public var rangeMin: Int?
    public var rangeMax: Int?
    public var currency = "USD"

    public init() {}
    enum CodingKeys: String, CodingKey {
        case currency, desiredBase = "desired_base", rangeMin = "range_min", rangeMax = "range_max"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        desiredBase = c.decodeLenientInt(forKey: .desiredBase)
        rangeMin = c.decodeLenientInt(forKey: .rangeMin)
        rangeMax = c.decodeLenientInt(forKey: .rangeMax)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(desiredBase, forKey: .desiredBase)  // explicit nulls, like 0.3's YAML
        try c.encode(rangeMin, forKey: .rangeMin)
        try c.encode(rangeMax, forKey: .rangeMax)
        try c.encode(currency, forKey: .currency)
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var willingToRelocate = false
    public var openToRemote = true
    public var openToHybrid = true
    public var openToOnsite = true
    public var noticePeriod = "2 weeks"
    public var earliestStartDate = "2 weeks after offer"
    public var over18 = true
    public var howDidYouHear = "LinkedIn"

    public init() {}
    enum CodingKeys: String, CodingKey {
        case willingToRelocate = "willing_to_relocate", openToRemote = "open_to_remote", openToHybrid = "open_to_hybrid"
        case openToOnsite = "open_to_onsite", noticePeriod = "notice_period", earliestStartDate = "earliest_start_date"
        case over18 = "over_18", howDidYouHear = "how_did_you_hear"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        willingToRelocate = try c.decodeIfPresent(Bool.self, forKey: .willingToRelocate) ?? false
        openToRemote = try c.decodeIfPresent(Bool.self, forKey: .openToRemote) ?? true
        openToHybrid = try c.decodeIfPresent(Bool.self, forKey: .openToHybrid) ?? true
        openToOnsite = try c.decodeIfPresent(Bool.self, forKey: .openToOnsite) ?? true
        noticePeriod = try c.decodeIfPresent(String.self, forKey: .noticePeriod) ?? "2 weeks"
        earliestStartDate = try c.decodeIfPresent(String.self, forKey: .earliestStartDate) ?? "2 weeks after offer"
        over18 = try c.decodeIfPresent(Bool.self, forKey: .over18) ?? true
        howDidYouHear = try c.decodeIfPresent(String.self, forKey: .howDidYouHear) ?? "LinkedIn"
    }
}

public struct Role: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var company = ""
    public var title = ""
    public var location = ""
    public var startDate = ""
    public var endDate = "Present"
    public var bullets: [String] = []

    public init(company: String = "", title: String = "", location: String = "", startDate: String = "", endDate: String = "Present",
                bullets: [String] = []) {
        self.company = company
        self.title = title
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.bullets = bullets
    }

    public var isCurrent: Bool { ["", "present", "current", "now"].contains(endDate.trimmed.lowercased()) }

    enum CodingKeys: String, CodingKey { case company, title, location, bullets, startDate = "start_date", endDate = "end_date" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        startDate = try c.decodeLenientString(forKey: .startDate)
        endDate = try c.decodeLenientString(forKey: .endDate, default: "Present")
        bullets = try c.decodeIfPresent([String].self, forKey: .bullets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(company, forKey: .company)
        try c.encode(title, forKey: .title)
        try c.encode(location, forKey: .location)
        try c.encode(startDate, forKey: .startDate)
        try c.encode(endDate, forKey: .endDate)
        try c.encode(bullets, forKey: .bullets)
    }
}

public struct Education: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var school = ""
    public var degree = ""
    public var fieldOfStudy = ""
    public var startDate = ""
    public var graduationDate = ""
    public var gpa = ""

    public init(school: String = "", degree: String = "", fieldOfStudy: String = "", graduationDate: String = "") {
        self.school = school
        self.degree = degree
        self.fieldOfStudy = fieldOfStudy
        self.graduationDate = graduationDate
    }

    enum CodingKeys: String, CodingKey {
        case school, degree, gpa, fieldOfStudy = "field_of_study", startDate = "start_date", graduationDate = "graduation_date"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        school = try c.decodeIfPresent(String.self, forKey: .school) ?? ""
        degree = try c.decodeIfPresent(String.self, forKey: .degree) ?? ""
        fieldOfStudy = try c.decodeIfPresent(String.self, forKey: .fieldOfStudy) ?? ""
        startDate = try c.decodeLenientString(forKey: .startDate)
        graduationDate = try c.decodeLenientString(forKey: .graduationDate)
        gpa = try c.decodeLenientString(forKey: .gpa)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(school, forKey: .school)
        try c.encode(degree, forKey: .degree)
        try c.encode(fieldOfStudy, forKey: .fieldOfStudy)
        try c.encode(startDate, forKey: .startDate)
        try c.encode(graduationDate, forKey: .graduationDate)
        try c.encode(gpa, forKey: .gpa)
    }
}

public struct EEO: Codable, Equatable, Sendable {
    public var gender = declineToSelfIdentify
    public var hispanicOrLatino = declineToSelfIdentify
    public var ethnicity = declineToSelfIdentify
    public var veteranStatus = declineToSelfIdentify
    public var disabilityStatus = declineToSelfIdentify
    public var sexualOrientation = declineToSelfIdentify
    public var pronouns = ""

    public init() {}
    enum CodingKeys: String, CodingKey {
        case gender, ethnicity, pronouns
        case hispanicOrLatino = "hispanic_or_latino", veteranStatus = "veteran_status", disabilityStatus = "disability_status"
        case sexualOrientation = "sexual_orientation"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gender = try c.decodeIfPresent(String.self, forKey: .gender) ?? declineToSelfIdentify
        hispanicOrLatino = try c.decodeIfPresent(String.self, forKey: .hispanicOrLatino) ?? declineToSelfIdentify
        ethnicity = try c.decodeIfPresent(String.self, forKey: .ethnicity) ?? declineToSelfIdentify
        veteranStatus = try c.decodeIfPresent(String.self, forKey: .veteranStatus) ?? declineToSelfIdentify
        disabilityStatus = try c.decodeIfPresent(String.self, forKey: .disabilityStatus) ?? declineToSelfIdentify
        sexualOrientation = try c.decodeIfPresent(String.self, forKey: .sexualOrientation) ?? declineToSelfIdentify
        pronouns = try c.decodeIfPresent(String.self, forKey: .pronouns) ?? ""
    }

    public static let choices: [String: [String]] = [
        "gender": ["Male", "Female", "Non-binary", declineToSelfIdentify],
        "hispanic_or_latino": ["Yes", "No", declineToSelfIdentify],
        "ethnicity": ["American Indian or Alaska Native", "Asian", "Black or African American",
                      "Native Hawaiian or Other Pacific Islander", "White", "Two or More Races", declineToSelfIdentify],
        "veteran_status": ["I am not a protected veteran", "I identify as one or more of the classifications of protected veteran",
                           declineToSelfIdentify],
        "disability_status": ["No, I do not have a disability", "Yes, I have a disability (or previously had a disability)",
                              declineToSelfIdentify],
    ]
}

public struct Files: Codable, Equatable, Sendable {
    public var resumePDF = "files/resume.pdf"
    public var coverLetterPDF: String?

    public init() {}
    enum CodingKeys: String, CodingKey { case resumePDF = "resume_pdf", coverLetterPDF = "cover_letter_pdf" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resumePDF = try c.decodeIfPresent(String.self, forKey: .resumePDF) ?? "files/resume.pdf"
        coverLetterPDF = try c.decodeIfPresent(String.self, forKey: .coverLetterPDF)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resumePDF, forKey: .resumePDF)
        try c.encode(coverLetterPDF, forKey: .coverLetterPDF)
    }
}

// MARK: - lenient decoding (hand-edited files and 0.3's YAML store numbers where text is expected, and vice versa)

extension KeyedDecodingContainer {
    func decodeLenientString(forKey key: Key, default fallback: String = "") throws -> String {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d == d.rounded() ? String(Int(d)) : String(d) }
        return fallback
    }

    func decodeLenientInt(forKey key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let digits = s.filter { $0.isNumber || $0 == "." }
            return Double(digits).map { Int($0) }
        }
        return nil
    }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

import Foundation

/// Answers that come straight from the profile, without the AI. Order matters: specific patterns first, and a rule that
/// matches but has no data stops the search (so "Portfolio" never falls through to a broader rule).
enum ProfileRules {
    typealias Rule = (Regex, (Profile, FieldSpec) -> String?)

    static func yn(_ v: Bool) -> String { v ? "Yes" : "No" }
    static func eeo(_ v: String) -> String { v.isEmpty ? declineToSelfIdentify : v }
    static func nonEmpty(_ s: String) -> String? { s.trimmed.isEmpty ? nil : s }

    /// "School", "University name", "School / education institution" (Infosys), "Name of college".
    static let schoolLabel = #"^(name of (the )?)?(school|university|college|(education(al)? )?institution)( name)?"#
        + #"(( ?/ ?| or )(school|university|college|(education(al)? )?institution)( name)?)?$"#

    /// Boxes for the person's own details, where the profile beats what a site read off the resume (Blue Yonder put
    /// "Peru" in Country, then turned the US phone number away).
    static let ownDetailsLabel = Regex(#"^((legal )?first|(legal )?last|family|given) name$|^e-?mail( address)?$|^(mobile |cell |home )?phone( number)?$|"#
        + #"^(street|(street |home )?address( line)?( 1| one)?|mailing address)$|^(city|town|city ?/ ?town|town ?/ ?city)$|^(state|province)( ?/ ?province)?$|^(zip|postal)( ?/ ?postal)?( code)?$|^post ?code$|^(current )?country( of (current )?residence)?$|"#
        + #"linkedin|github|portfolio|^website$|^selected country$|^select(ed)? (a |the |your )?country (calling |dial(ing)? |phone )?code\b|^(phone |mobile )?country (phone |calling |dial(ing)? )?code$|^phone (number )?country( code)?$"#)

    /// Boxes for the person's own links: LinkedIn, GitHub, a portfolio or website.
    static let linkLabel = Regex(#"linkedin|github|portfolio|personal (web)?site|^website$|^other website"#)

    /// A link the way every form takes it: with https://, and a LinkedIn profile in LinkedIn's own form
    /// (https://www.linkedin.com/in/name). Workday turns away "linkedin.com/in/name".
    static func link(_ s: String) -> String? {
        var t = s.trimmed
        guard !t.isEmpty else { return nil }
        if !Regex(#"^https?://"#).matches(t) { t = "https://" + t }
        guard var c = URLComponents(string: t), let host = c.host?.lowercased() else { return t }
        if host == "linkedin.com" || host.hasSuffix(".linkedin.com") {
            c.scheme = "https"
            c.host = "www.linkedin.com"
            while c.path.count > 1 && c.path.hasSuffix("/") { c.path.removeLast() }
            c.query = nil
            c.fragment = nil
            return c.string ?? t
        }
        return t
    }

    /// Where the person heard of the job among the site's choices: itself, or for a job board the site doesn't list
    /// (LinkedIn among "Online Job Board, Company Website, …") the choice for job boards. Nil when none fits.
    static func sourceOption(_ source: String, _ options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        if let same = matchOption(source, options) { return same }
        // The one choice that names it among others ("LinkedIn job posting", Flexport's "Career Platform (LinkedIn,
        // Glassdoor, BuiltIn, etc.)").
        let word = norm(source)
        if !word.isEmpty {
            let naming = options.filter { Regex("\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b").matches(norm($0)) }
            if naming.count == 1 { return naming[0] }
        }
        guard Regex(#"linkedin|indeed|glassdoor|ziprecruiter|dice|monster|handshake|wellfound|built ?in"#).matches(norm(source)) else { return nil }
        for kind in sourceKinds {
            if let o = options.first(where: { Regex(kind).matches(norm($0)) }) { return o }
        }
        return nil
    }

    /// The kinds of place a job site is, in the order its choices are tried.
    static let sourceKinds = [#"job ?boards?|job (site|search|posting)|online job|internet job|career (site|website)"#, #"social (media|network)"#, #"^online$|^internet$"#, #"^other\b"#]

    /// The list that names the place once its kind is chosen ("Source" under "How Did You Hear About Us?" on Phenom).
    static let subSourceLabel = Regex(#"^(source|applicant source|source name|specific source|source detail|which one|please specify( source)?)$"#)
    static let hearLabel = Regex(#"how (did|have) you (first |initially |originally )?(hear|heard|find|found|learn|learned)|referral source|^source type$"#)

    /// The next kind to try when the list under the one chosen doesn't name the job site (Toyota's "Job Board" lists
    /// Dice and Indeed; LinkedIn is under "Social Media"). Nil once every kind has been tried.
    static func nextSourceKind(after chosen: String, _ options: [String], source: String) -> String? {
        guard Regex(#"linkedin|indeed|glassdoor|ziprecruiter|dice|monster|handshake|wellfound|built ?in"#).matches(norm(source)) else { return nil }
        let index = { (o: String) in sourceKinds.firstIndex { Regex($0).matches(norm(o)) } }
        guard let now = index(chosen) else { return nil }
        for k in (now + 1)..<sourceKinds.count {
            if let o = options.first(where: { Regex(sourceKinds[k]).matches(norm($0)) }) { return o }
        }
        return nil
    }

    /// "Where would you like to receive a verification code?" (ADP's, choosing the phone or the email).
    static let codeDestinationLabel = #"\b(where|how) (would|do|should|can) (you|we) (like to |want to |prefer to )?(receive|get|send)\b.{0,40}\b(code|passcode|pin)\b|"#
        + #"\bsend (the |a |your )?(verification |security |one[- ]time )?(code|passcode) to\b"#

    /// Pay asked in other terms than the profile's yearly figure: by the month, hour, day or week, after tax ("net"), or
    /// in another currency (Envipco's "monthly NET salary expectation in RON" got the yearly US dollars). The person's
    /// to say, not a figure to convert.
    static func salaryInOtherTerms(_ f: FieldSpec, _ p: Profile) -> Bool {
        let n = norm(f.label), raw = f.label.lowercased()
        guard f.type != .checkbox, Regex(#"salary|compensation|\bpay\b|\bwages?\b|remuneration|\brate\b|\bctc\b"#).matches(n) else { return false }
        if Regex(#"\b(monthly|per month|a month|hourly|per hour|an hour|daily|per day|day rate|weekly|per week|net)\b"#).matches(n) { return true }
        var named = Set(Regex(#"\b(usd|eur|gbp|inr|cad|aud|ron|pln|chf|sek|nok|dkk|jpy|cny|rmb|brl|mxn|zar|sgd|hkd|nzd|aed|ils|czk|huf|try|uah|php|pkr|egp|ngn|kes|cop|clp|pen|ars|bgn|rsd)\b"#)
            .allMatches(n).map { $0.uppercased() })
        for (mark, code) in [("€", "EUR"), ("£", "GBP"), ("₹", "INR"), ("¥", "JPY"), ("₱", "PHP"), ("zł", "PLN"), (" lei", "RON"), ("euro", "EUR"),
                             ("pound", "GBP"), ("rupee", "INR")] where raw.contains(mark) { named.insert(code) }
        let mine = p.compensation.currency.trimmed.isEmpty ? "USD" : p.compensation.currency.uppercased()
        return !named.isEmpty && !named.contains(mine)
    }

    /// The country of a phone number: "Selected country" next to the number, "Country Phone Code", "Country code".
    static let phoneCountryLabel = #"^selected country$|^select(ed)? (a |the |your )?country (calling |dial(ing)? |phone )?code\b|^(phone |mobile )?country (phone |calling |dial(ing)? )?code$|^phone (number )?country( code)?$|^(dial(ing)?|calling) code$"#

    /// The profile's country in the site's words: "United States +1", "USA (+1)", or just "+1".
    static func phoneCountry(_ p: Profile, _ f: FieldSpec) -> String? {
        let country = p.personal.address.country.trimmed.isEmpty ? "United States" : p.personal.address.country
        let real = f.options.filter { !isPlaceholderOption($0) }
        // Only dialing codes: the profile's number's own ("+1 512…"), else +1 for the US and Canada.
        let digits = p.personal.phone.trimmed
        let code = digits.hasPrefix("+") ? String(digits.dropFirst().prefix { $0.isNumber }.prefix(3)) : (inUS(p) || norm(country) == "canada" ? "1" : "")
        guard !real.isEmpty else {
            // A box that already shows the number's code (SmartRecruiters' "+1" beside a flag, whose list the app can't
            // read): kept, not replaced by the country's name.
            if !code.isEmpty, f.currentValue.replacingOccurrences(of: " ", with: "") == "+" + code { return f.currentValue }
            return country
        }
        if let named = matchOption(country, real) { return named }
        guard !code.isEmpty else { return nil }
        for n in (1...code.count).reversed() {
            let want = "+" + code.prefix(n)
            if let o = real.first(where: { $0.replacingOccurrences(of: " ", with: "") == want }) { return o }
        }
        return nil
    }

    /// A list of job boards under a label that doesn't say what it is (Lockheed's "Details" after "How did you hear
    /// about us?"): where the person heard of the job, when it's one of them.
    static func jobBoardList(_ p: Profile, _ f: FieldSpec) -> String? {
        let boards = Regex(#"^(linkedin|indeed|glassdoor|ziprecruiter|dice|monster|handshake|careerbuilder|simply ?hired|snagajob|flexjobs|ladders|wellfound|built ?in)\b"#)
        guard f.options.filter({ boards.matches(norm($0)) }).count >= 4, !p.preferences.howDidYouHear.isEmpty else { return nil }
        return matchOption(p.preferences.howDidYouHear, f.options)
    }

    /// "Location Preference" among offices ("Burlingame, CA", "Austin, TX", "Remote"): the office in the person's own city.
    static let officeLabel = Regex(#"^(work |office )?location preferences?$|^preferred (work |office )?locations?$|which (of (our|the|these) )?(offices?|locations?)\b.{0,40}\b(prefer|work|interested|like)|where would you (like|prefer) to (work|be based)|^(in )?(what|which) cit(y|ies) (are you|would you)"#)

    static func ownOffice(_ p: Profile, _ f: FieldSpec) -> String? {
        let city = norm(p.personal.address.city)
        guard !city.isEmpty, !f.options.isEmpty else { return nil }
        let mine = f.options.filter { o in Regex("^" + NSRegularExpression.escapedPattern(for: city) + "\\b").matches(norm(o)) }
        return mine.count == 1 ? mine[0] : nil
    }

    static func inUS(_ p: Profile) -> Bool {
        Regex(#"^(united states( of america)?|u\.?s\.?(a\.?)?|america)$"#).matches(norm(p.personal.address.country))
    }

    /// "Have you previously been employed by Booz Allen?", "Do you currently work or have you previously worked … for
    /// Comcast or any Company within the Comcast Family?", "Are you a previous Employee of PayPal …?": from the work history. Not questions about relatives or
    /// friends who work there.
    static func formerEmployee(_ p: Profile, _ f: FieldSpec, company: String) -> String? {
        guard [.radio, .select, .combobox, .checkbox].contains(f.type) || f.options.count == 2 else { return nil }
        let label = norm(f.label)
        guard Regex(#"\b(previous(ly)?|ever|formerly|before|prior|former|past|currently)\b"#).matches(label),
              Regex(#"\b(employ(ed|ee|ment)|work(ed|ing)?|contractor|intern(ed)?)\b"#).matches(label),
              !Regex(#"relative|family member|spouse|friend|know anyone|related to|referr"#).matches(label) else { return nil }
        let skip: Set<String> = ["inc", "llc", "corp", "corporation", "company", "co", "the", "group", "ltd", "limited", "holdings", "technologies", "services"]
        let words = norm(company).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !skip.contains($0) }
        let thisOne = Regex(#"\bthis (organi[sz]ation|company|employer|firm)\b|\bour (company|organi[sz]ation)\b|\b(with|for) us\b|\bworked here\b"#).matches(label)
        // The name written apart or together ("New Relic" for "newrelic", "Pure Storage" for "PureStorage").
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let whole = squash(company.replacingOccurrences(of: #"\b(inc|llc|corp|corporation|ltd|limited)\b\.?"#, with: "", options: [.regularExpression, .caseInsensitive]))
        let named = { (text: String) in
            guard let name = words.first else { return false }
            return Regex("\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b").matches(norm(text)) || (whole.count >= 5 && squash(text).contains(whole))
        }
        guard !words.isEmpty, thisOne || named(f.label) else { return nil }
        let worked = p.workHistory.contains { named($0.company) }
        // Choices that say how ("I have not previously been employed at Affirm", "No - I have not worked at Squarespace
        // before"): the one that says never, for someone who never did. Someone who did picks the kind themselves.
        let real = f.options.filter { !isPlaceholderOption($0) }
        if !real.isEmpty, !real.contains(where: { ["yes", "no"].contains(norm($0)) }) {
            guard !worked else { return nil }
            let never = real.filter { Regex(#"^no\b|\b(not|never|haven'?t|have not)\b"#).matches(norm($0)) }
            return never.count == 1 ? never[0] : nil
        }
        return yn(worked)
    }

    static func isUSCitizen(_ p: Profile) -> Bool {
        let status = "\(p.workAuthorization.visaStatus) \(p.workAuthorization.citizenship)".lowercased()
        return (status.contains("citizen") && !status.contains("non")) || p.workAuthorization.citizenship.lowercased().contains("united states")
    }

    static let rules: [Rule] = {
        func r(_ pattern: String, _ fn: @escaping (Profile, FieldSpec) -> String?) -> Rule { (Regex(pattern), fn) }
        return [
            // "Are you currently a student?", "Are you currently pursuing a Bachelor's or Master's degree?": not when
            // every school in the profile is finished (the AI once answered "Bachelor's").
            r(studentQuestion) { p, f in studentNow(p, f) },
            // Where to send a verification code (ADP's choice of the phone number or the email): the email, which the
            // app reads; never the phone, whose texts it can't.
            r(codeDestinationLabel) { p, f in
                let mail = norm(p.personal.email)
                return f.options.first { !mail.isEmpty && norm($0).contains(mail) } ?? f.options.first { Regex(#"\be-?mail\b"#).matches(norm($0)) }
            },
            r(#"phone (device )?type|type of phone|^device type$"#) { _, _ in "Mobile" },
            // The phone number's country (sites guess it from where the computer is: "Peru +51" for a US number).
            r(phoneCountryLabel) { p, f in phoneCountry(p, f) },
            // A form signed by typing (SmartRecruiters' "Name (Signature Field):" and "Today's date").
            r(#"^(today'?s|current) date\b|^date( of)? signature\b|^(signature|signed) date\b|^date signed\b|^date$"#) { _, f in
                f.type == .text || f.type == .date ? today(for: f) : nil
            },
            r(#"\bsignature\b|\belectronic(ally)? sign|^type your (full )?(legal )?name\b|^(please )?sign (here|below)\b"#) { p, f in
                f.type == .text ? nonEmpty(p.personal.fullName) : nil
            },
            r(degreeQuestion) { p, f in hasDegree(p, asked: norm(f.label)).map(yn) },
            r(#"country (phone )?code|phone (country )?code|dialing code"#) { p, _ in nonEmpty(p.personal.phoneCountryCode) },
            r(#"time ?zone"#) { p, _ in TimeZones.of(p) },
            // Workday's "I have a preferred name" box, which adds a second set of name boxes when ticked.
            r(#"^(i have|do you have|i use|do you use|use) an? (different )?preferred (first )?name\??$"#) { p, f in
                guard f.type == .checkbox || f.type == .radio || f.type == .select else { return nil }
                let preferred = p.personal.preferredName.trimmed
                return yn(!preferred.isEmpty && norm(preferred) != norm(p.personal.firstName))
            },
            // A sign-up's "User Name" (Taleo's: no spaces): the email, which is what the app signs in with (the AI
            // once gave the full name, and the account was never made).
            r(#"^(choose |create |pick |enter )?(a |your )?(user ?name|user ?id|login( id| name)?|sign[- ]?in (id|name))$"#) { p, _ in nonEmpty(p.personal.email) },
            r(#"\bpreferred (first )?name\b|\bnickname\b"#) { p, _ in nonEmpty(p.personal.preferredName) ?? nonEmpty(p.personal.firstName) },
            r(#"\bfirst name\b|\bgiven name\b"#) { p, _ in nonEmpty(p.personal.firstName) },
            r(#"\blast name\b|\bfamily name\b|\bsurname\b"#) { p, _ in nonEmpty(p.personal.lastName) },
            r(#"^(your )?(full |legal |full legal )?name$|^candidate name$"#) { p, _ in nonEmpty(p.personal.fullName) },
            r(#"e-?mail"#) { p, _ in nonEmpty(p.personal.email) },
            r(#"\b(phone|mobile|cell)( number)?\b(?!.*\bext(ension)?\b)"#) { p, f in extensionLabel.matches(norm(f.label)) ? nil : nonEmpty(p.personal.phone) },
            r(#"linkedin"#) { p, _ in link(p.personal.linkedin) },
            r(#"github"#) { p, _ in link(p.personal.github) },
            r(#"portfolio|personal (web)?site|^website$|^other website"#) { p, _ in link(p.personal.portfolio) ?? link(p.personal.github) },
            r(#"(street|address line 1|^address$|mailing address|^((home|street|mailing|current|permanent|residential) )?address( line)? ?(1|one)$|^(home|permanent|current|residential) address$)"#) { p, f in
                addressLine2.matches(norm(f.label)) ? nil : nonEmpty(p.personal.address.street)
            },
            // LinkedIn's "Location (city)" suggests "Springfield, Illinois, United States" as you type: the city with its
            // state picks the right Springfield.
            r(#"^location \(city\)$"#) { p, _ in nonEmpty(p.personal.displayLocation) },
            r(#"^city$|\bcity\b(?!.*(willing|relocat|prefer|like to))|^town( ?/ ?city)?$"#) { p, _ in nonEmpty(p.personal.address.city) },
            r(#"^(state|province)( ?/ ?(province|region|state)| or province)?( (select|choose) (a|an|your|the) (state|province))?$|state ?/ ?province|state or province|^state of residence$"#) { p, _ in nonEmpty(p.personal.address.state) },
            r(#"zip|postal|^post ?code$"#) { p, _ in nonEmpty(p.personal.address.postalCode) },
            r(#"^(current )?country$|country of (current )?residence|country/region|^(current )?country (of|where) you (live|reside)|^(in )?which country do you (currently )?(live|reside)"#) { p, _ in nonEmpty(p.personal.address.country) },
            r(#"^(current )?location$|where are you (currently )?(located|based)|^location \(city\)"#) { p, _ in nonEmpty(p.personal.location) ?? nonEmpty(p.personal.displayLocation) },
            r(#"(located|living|residing|reside|based) in the (united states|u\.? ?s\.?( ?a\.?)?)\b|(live|reside) in the (united states|u\.? ?s\.?)\b"#) { p, _ in
                p.personal.address.country.isEmpty ? nil : yn(inUS(p))
            },
            r(#"(legally )?authori[sz]ed to work|eligible to work|right to work|work authori[sz]ation"#) { p, _ in yn(p.workAuthorization.authorizedToWork) },
            r(#"sponsor"#) { p, _ in yn(p.workAuthorization.requiresSponsorship) },
            r(#"are you (a )?(u\.?s\.?|united states) citizen"#) { p, _ in yn(isUSCitizen(p)) },
            r(#"security clearance|active clearance"#) { p, _ in nonEmpty(p.workAuthorization.securityClearance) },
            r(#"relocat"#) { p, _ in yn(p.preferences.willingToRelocate) },
            r(officeWillingness) { p, f in officeDays(p, f) },
            // A notice period asked as a date (Teamtailor's date box for "What is your current notice period?"): the day
            // the notice ends, counted from today.
            r(#"notice period"#) { p, f in
                guard f.type == .date else { return nonEmpty(p.preferences.noticePeriod) }
                return noticeEnds(p.preferences.noticePeriod).map { today(for: f, now: $0) }
            },
            r(#"earliest.*start|when can you start|available to start|availability to start|desired start date"#) { p, f in
                nonEmpty(p.preferences.earliestStartDate).map { startDate($0, for: f) }
            },
            r(#"(18|eighteen) years|at least 18|over the age of"#) { p, _ in yn(p.preferences.over18) },
            r(#"how (did|have) you (first |initially |originally )?(hear|heard|find|found|learn|learned)|where (did|have) you (first |initially |originally )?(hear|heard|find|found|see|seen|learn|learned)|referral source|^source$"#) { p, f in
                nonEmpty(p.preferences.howDidYouHear).map { sourceOption($0, f.options) ?? $0 }
            },
            r(#"(desired|expected|target) (salary|compensation|pay)|salary expectation|compensation expectation|^salary$"#) { p, f in
                salaryInOtherTerms(f, p) ? nil : p.compensation.desiredBase.map(String.init)
            },
            r(#"(current|most recent) (company|employer)|^company$|^employer$"#) { p, _ in p.currentRole.flatMap { nonEmpty($0.company) } },
            r(#"(current|most recent) (job )?(title|position|role)"#) { p, _ in p.currentRole.flatMap { nonEmpty($0.title) } },
            r(schoolLabel) { p, _ in p.education.first.flatMap { nonEmpty($0.school) } },
            r(#"field of study|^major$|discipline"#) { p, _ in p.education.first.flatMap { nonEmpty($0.fieldOfStudy) } },
            // Questions the profile keeps no answer for ("Are you a person of transgender experience?", "Do you consider
            // yourself a member of the LGBTQIA+ community?"): declined where the list offers that.
            r(#"transgender|cisgender|\blgbt|^i identify as:?$"#) { _, _ in declineToSelfIdentify },
            r(#"\bgender\b|^(biological |legal )?sex( at birth)?$|\b(identify|indicate|select|specify|state) your sex\b|^(your |what is your )sex\b"#) { p, _ in eeo(p.eeo.gender) },
            r(#"hispanic|latino"#) { p, _ in eeo(p.eeo.hispanicOrLatino) },
            r(#"\brace\b|ethnic"#) { p, _ in eeo(p.eeo.ethnicity) },
            r(#"veteran"#) { p, _ in eeo(p.eeo.veteranStatus) },
            r(#"disabilit"#) { p, _ in eeo(p.eeo.disabilityStatus) },
            r(#"sexual orientation"#) { p, _ in eeo(p.eeo.sexualOrientation) },
            r(#"pronoun"#) { p, _ in nonEmpty(p.eeo.pronouns) },
            r(#"years|how many|how long"#) { p, f in f.type == .textarea ? nil : yearsFor(p, f.label) },
        ]
    }()

    /// "Title" with "Mr.", "Ms.", "Dr." to choose from (not a job title): from the profile's gender, else the person's
    /// own answer (never guessed from a name).
    static func honorific(_ p: Profile, _ f: FieldSpec) -> String? {
        guard isHonorific(f) else { return nil }
        switch p.eeo.gender.lowercased() {
        case "male", "man": return f.options.first { Regex(#"^mr\.?$"#).matches(norm($0)) }
        case "female", "woman": return f.options.first { Regex(#"^(ms|mrs|miss)\.?$"#).matches(norm($0)) }
        default: return nil
        }
    }

    static func isHonorific(_ f: FieldSpec) -> Bool {
        Regex(#"^(name )?(title|salutation|prefix|honorific)$"#).matches(norm(f.label))
            && f.options.contains { Regex(#"^(mr|ms|mrs|miss|mx|dr)\.?$"#).matches(norm($0)) }
    }

    /// A box for the person's skills ("Skills", "Key skills", "Enter your skills… (Maximum 5)").
    static let skillsLabel = Regex(#"^(your |key |top |primary |main |technical |core )?skills?( ?set)?$|^enter your skills"#)

    /// The profile's skills for a skills box, without their notes ("Flutter (Wordool ↗)" → "Flutter"): those the job
    /// mentions first, then in the profile's order; up to `limit`, separated by "; ".
    static func skills(_ p: Profile, job: JobContext, limit: Int) -> String? {
        let names = p.skills.map { s -> String in
            let bare = Regex(#"\s*\(.*$"#, []).replace(s, with: "").trimmed
            return bare.isEmpty ? s.trimmed : bare
        }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let text = norm("\(job.title) \(job.description)")
        func mentioned(_ name: String) -> Bool {
            Regex(#"(?<![a-z0-9+#])"# + NSRegularExpression.escapedPattern(for: norm(name)) + #"(?![a-z0-9+#])"#).matches(text)
        }
        let ranked = names.filter(mentioned) + names.filter { !mentioned($0) }
        var seen = Set<String>()
        return ranked.filter { seen.insert($0.lowercased()).inserted }.prefix(max(1, limit)).joined(separator: "; ")
    }

    /// A name's "Prefix" or "Suffix" ("Jr.", "Sr.", "III"): the profile has none, so these are never guessed.
    /// A box for the letters in a picture (a CAPTCHA): "Type below image text", "Enter the characters shown in the image".
    static let pictureCheck = Regex(#"\b(enter|type|solve)( the)? captcha\b|\bcaptcha( code| text| answer| response)?\W*$|\b(below|above|in the|from the) (image|picture) text\b|\b(type|enter) (the )?(text|characters|letters|code|words?)( shown| you see)? (in|from|on|below|above) (the )?(image|picture)\b|\b(image|picture) (text|code|verification)\b"#)

    /// A question about the person's grades: "Undergraduate GPA", "CGPA", "Overall result (GPA)", "Do you have a
    /// cumulative GPA of 3.0 or higher?".
    static let gpaLabel = Regex(#"\bc?gpa\b|grade point average|\bcumulative (grade|average)\b"#)

    static let nameAffixLabel = Regex(#"^(name )?(suffix|prefix)$|^(name )?suffix \(|^generational suffix\b"#)

    /// "Middle name", "Middle initial", "M.I.": the profile has none, so these are never guessed.
    static let middleLabel = Regex(#"^m\.? ?i\.?$|\bmiddle (name|initial)s?\b|^middle$|\bsecond(ary)? (last )?name\b|\bsecond surname\b|\bmaternal (last )?name\b"#)

    /// A box for an account on a network the profile keeps no link for ("Facebook", "X (fka Twitter)", "Instagram"):
    /// any answer would be made up (the on-device AI put the headline there).
    static let otherNetworkLabel = Regex(#"^(your )?(facebook|twitter|x|instagram|tiktok|threads|mastodon|bluesky|snapchat|youtube|dribbble|behance|xing|wechat|weibo)\b[^?]{0,30}$"#)

    /// A phone extension: the profile has none (Blue Yonder's got the whole number).
    /// A second street line ("Address 2", "Apt/Suite"): the profile has one street line, so it stays empty (Infosys's
    /// got the city).
    static let addressLine2 = Regex(#"^((street|mailing|home|current|permanent) )?address( \(?line)? ?(2|two|ii)\b|\baddress \(?line ?2\b|^(apt|apartment|suite|unit|floor)( ?(/|,|or) ?(apt|apartment|suite|unit|floor|building))*( (number|no\.?|#))?$"#)

    static let extensionLabel = Regex(#"\bext(ension)?\b|\bext\.?$"#)

    /// Details of a job at this company the person may have had ("Who was your Manager?", "What was your Employee
    /// ID?", "What was your JDA/Blue Yonder email?"): asked of former employees only.
    static let formerJobDetail = Regex(#"^(what|who|when|where) (was|were) your\b.{0,40}\b(manager|supervisor|employee (id|number)|e-?mail|location|department|business unit|title|position|dates?|start date|end date)\b"#)

    /// "Do you have a minimum of a Bachelor's degree or foreign equivalent…?"
    static let degreeQuestion = #"(do you (have|possess|hold)|have you (completed|earned|obtained|received|attained)).{0,40}\b(bachelor'?s?|undergraduate|master'?s?|graduate|doctoral|doctorate|ph\.? ?d)\b.{0,30}\bdegree\b"#

    /// Whether the profile's education reaches the level the question asks for; nil without education.
    /// 3 for a doctorate, 2 for a master's, 1 for a bachelor's, 0 when the words don't say.
    static func degreeLevel(_ s: String) -> Int {
        let t = norm(s)
        if Regex(#"doctor|ph\.? ?d|\bd\.?phil"#).matches(t) { return 3 }
        if Regex(#"master|\bm\.? ?(s|a|eng|sc|ba|phil)\b|\bmba\b|graduate degree"#).matches(t) { return 2 }
        if Regex(#"bachelor|\bb\.? ?(s|a|eng|sc|tech)\b|undergraduate"#).matches(t) { return 1 }
        return 0
    }

    static func hasDegree(_ p: Profile, asked: String) -> Bool? {
        let level = degreeLevel
        let degrees = p.education.map(\.degree).filter { !$0.trimmed.isEmpty }
        guard !degrees.isEmpty else { return nil }
        let want = Regex(#"doctor|ph\.? ?d"#).matches(asked) ? 3 : Regex(#"master|\bgraduate degree"#).matches(asked) && !Regex(#"undergraduate"#).matches(asked) ? 2 : 1
        return degrees.map(level).max() ?? 0 >= want
    }

    static let genericExperience = Regex(
        #"((what (is|are)|please (enter|indicate|state|specify|provide)|enter|indicate|specify|provide) )?(your )?"#
        + #"(how many |total )?(years of )?((total|professional|work|relevant|industry|overall|hands[- ]on|production[- ]level|full[- ]time),? (and )?)*"#
        + #"(software |engineering |software engineering |software development )?(work )?(years of )?experience( do you have)?( in total)?( \(years\))?"#)

    /// Years for the skill a question names; the overall number only for a question about overall experience.
    /// A skill only matches as a whole token, so "C" doesn't answer for "C++" or "C#" (a bug in version 0.3).
    static func yearsFor(_ p: Profile, _ label: String) -> String? {
        let n = norm(label)
        var best: (Int, Double)?
        for (skill, years) in p.experienceYears {
            let key = norm(skill)
            if ["total", "overall", "professional"].contains(key) || key.isEmpty { continue }
            let pattern = Regex(#"(?<![a-z0-9+#])"# + NSRegularExpression.escapedPattern(for: key) + #"(?![a-z0-9+#])"#)
            if pattern.matches(n), best == nil || key.count > best!.0 { best = (key.count, years) }
        }
        if let best { return String(Int(best.1.rounded())) }
        // "(Academic experience or internships excluded)" after the question doesn't change it.
        let bare = n.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s?*:.]+$"#, with: "", options: .regularExpression)
        if genericExperience.fullMatch(bare), bare.contains("years"), let total = p.totalYears { return String(Int(total.rounded())) }
        return nil
    }

    /// "If you were referred by a Current Employee, please list their name. If this is not applicable, please list N/A."
    /// (Tenex's): the form names its own answer for no referrer, and the person's "how did you hear" says how they came
    /// instead. A name is never made up: a profile that says referral (or says nothing) leaves it to the person.
    static func noReferrer(_ p: Profile, _ f: FieldSpec, _ label: String) -> String? {
        guard [.text, .textarea].contains(f.type),
              Regex(#"\breferr(ed|al|er)\b"#).matches(label),
              Regex(#"(not applicable|\bif (none|not|no one|you were not|you weren't|n/a)\b|\botherwise\b).{0,60}\bn/a\b|\bn/a\b.{0,20}\bif (none|not|no one)\b"#).matches(label)
        else { return nil }
        let heard = norm(p.preferences.howDidYouHear)
        guard !heard.isEmpty, !Regex(#"referr|employee|friend|recommend|colleague|someone (who )?works"#).matches(heard) else { return nil }
        return "N/A"
    }

    static func answer(_ p: Profile, _ f: FieldSpec) -> String? {
        let label = norm(f.label)
        guard !label.isEmpty else { return nil }
        if !p.extraAnswers.isEmpty {
            var keys: [String: String] = [:]
            for (k, v) in p.extraAnswers { keys[norm(k)] = v }
            if let v = keys[norm(f.contextLabel)] ?? keys[label] { return v }
            if let close = Difflib.closeMatch(label, Array(keys.keys), cutoff: 0.9) { return keys[close] }
        }
        if let checked = attentionCheck(f, label) { return checked }
        if [.radio, .select, .combobox, .checkboxGroup].contains(f.type), let board = jobBoardList(p, f) { return board }
        if [.radio, .select, .combobox, .checkboxGroup].contains(f.type), officeLabel.matches(label), let office = ownOffice(p, f) { return office }
        if [.checkbox, .radio, .select, .combobox, .checkboxGroup].contains(f.type), let choice = consentOrSignup(f, label) { return choice }
        if FieldSpec.ambiguous.matches(label) {
            switch f.section {
            case "Education":
                // A name, email or phone under "Education" is the person's own (the page's headings put it there).
                if let v = education(p, f, label) { return v }
                if !ownContactLabel.matches(label) { return nil }
            case "Work experience": return work(p, f, label)
            case "References", "Emergency contact", "Referral": return nil  // someone else's details, never the person's own
            default: break
            }
        }
        if let none = noReferrer(p, f, label) { return none }
        for (pattern, fn) in rules where pattern.matches(label) {
            return fn(p, f)  // a matching rule without data stops here
        }
        // A list under a heading that isn't its question (Infosys's "Form CC-305 Page 1 of 1" over "Yes, I have a
        // disability…"): what the person said about the topic its choices name.
        if !f.label.contains("?"), let topic = selfIdentificationTopic(f) {
            switch topic {
            case .disability: return eeo(p.eeo.disabilityStatus)
            case .veteran: return eeo(p.eeo.veteranStatus)
            case .hispanic: return eeo(p.eeo.hispanicOrLatino)
            case .race: return eeo(p.eeo.ethnicity)
            case .sexualOrientation: return eeo(p.eeo.sexualOrientation)
            case .gender: return eeo(p.eeo.gender)
            case .pronouns: return nonEmpty(p.eeo.pronouns)
            default: return nil
            }
        }
        return nil
    }

    /// The self-identification topic a list's choices give away ("No, I do not have a disability and have not had one
    /// in the past", "I am not a protected veteran", "Black or African American"), for when its label doesn't.
    static func selfIdentificationTopic(_ f: FieldSpec) -> QuestionTopic? {
        guard [.radio, .select, .combobox, .checkboxGroup].contains(f.type), f.options.count >= 2 else { return nil }
        let options = f.options.map(norm)
        let any = { (pattern: String) in let re = Regex(pattern); return options.contains { re.matches($0) } }
        if any(#"\bi (do not |don't )?have a disability\b|\bhave had (a disability|one) in the past\b"#) { return .disability }
        if any(#"\bprotected veteran\b|\bi am (not )?a veteran\b"#) { return .veteran }
        if any(#"^(not |no,? i am not )?hispanic or latin[oax]\b"#) { return .hispanic }
        if any(#"black or african american|american indian or alaska(n)? native|native hawaiian or (other )?pacific islander|two or more races"#) { return .race }
        if any(#"^(heterosexual|straight)\b|\bbisexual\b|\blesbian\b"#) { return .sexualOrientation }
        if any(#"\b(he/him|she/her|they/them)\b"#) { return .pronouns }
        if any(#"^(male|man)$"#) && any(#"^(female|woman)$"#) { return .gender }
        return nil
    }

    /// "Are you willing to come into the office during the week (3 days) according to our hybrid policy?" (Tinder's),
    /// "Are you comfortable working on-site five days a week?": the profile's own workplace preferences.
    static let officeWillingness = #"\b(willing|open|comfortable|ok|okay|happy|agree|able)\b.*\b(hybrid|on-?site|in[- ]office|in(to)? (the |our |an )?office|in[- ]person)\b"#

    /// Not whether the person can get there ("able to commute to …", "live within 50 miles"): that's where they live,
    /// nor an interview in person.
    static func officeDays(_ p: Profile, _ f: FieldSpec) -> String? {
        guard f.type != .textarea else { return nil }
        let label = norm(f.label)
        if Regex(#"commut|\blive\b|\breside|miles|\bdistance|travel|interview|remote"#).matches(label) { return nil }
        if Regex(#"hybrid|\b[1-4] days?\b|\b(one|two|three|four) days?\b"#).matches(label) { return yn(p.preferences.openToHybrid) }
        return yn(p.preferences.openToOnsite)
    }

    static let studentQuestion = #"^(are|r) you (currently |still |now )?(a (current |full[- ]time |part[- ]time |university |college )?student\b|(currently )?(enrolled|pursuing|studying|attending)\b)"#

    /// "No" (or the list's "None"/"Neither") when every school in the profile has ended; nil otherwise.
    static func studentNow(_ p: Profile, _ f: FieldSpec) -> String? {
        guard !p.education.isEmpty else { return nil }
        let now = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        let finished = p.education.allSatisfy { e in
            let g = dateParts(e.graduationDate)
            guard let y = g.endYear else { return false }
            return y < (now.year ?? 0) || (y == now.year && (g.month ?? 12) < (now.month ?? 1))
        }
        guard finished else { return nil }
        if f.options.isEmpty { return "No" }
        return matchOption("No", f.options)
            ?? f.options.first { Regex(#"^(no|none|neither|not (currently )?(a student|enrolled|pursuing))\b"#).matches(norm($0)) }
    }

    /// The person's own name, email or phone.
    static let ownContactLabel = Regex(#"^((full |first |last |legal )?name|e-?mail( address)?|(mobile |cell |primary )?phone( number)?)( \d+)?$"#)

    /// Questions that check the person reads them ("To be considered, please pick the opposite of Yes.", "Select No for
    /// this question"): what they ask for. Rippling's job boards ask one.
    static func attentionCheck(_ f: FieldSpec, _ label: String) -> String? {
        let flip = ["yes": "no", "no": "yes", "true": "false", "false": "true"]
        var want: String?
        if let g = Regex(#"\bopposite of\W+(yes|no|true|false)\b"#).firstGroups(label), let w = g[1] {
            want = flip[w]
        } else if let g = Regex(#"\b(select|pick|choose|answer|click|mark|check|type|enter|write)\W+(yes|no|true|false)\W+(for|to|on|in|as|if)\b"#).firstGroups(label),
                  let w = g[2], Regex(#"\b(this|the) question\b|\bshow\b|\bread\b|\bhuman\b|\bpaying attention\b|\bconsidered\b"#).matches(label) {
            want = w
        }
        guard let want else { return nil }
        if f.options.isEmpty { return f.type == .checkbox ? (want == "yes" || want == "true" ? "Yes" : "No") : want.capitalized }
        return f.options.first { norm($0) == want }
    }

    // MARK: sections

    static let signup = Regex(#"(text|sms|whatsapp) messag|\bsms\b|\bwhatsapp\b|\bopt[- ]?in to receive\b|newsletter|marketing|promotional|job alerts?|talent (community|network|pool)|subscribe|"#
                              + #"similar (jobs|roles|opportunities)|future (job )?(opportunit|openings?|postings?|roles|positions|vacanc)|keep me (informed|updated)|contact me about|"#
                              + #"(e-?mail|notify|text) me (about|of|when)|join .{0,40}communit|"#
                              + #"\b(agree|consent) to receive (e-?mail|marketing|promotional|recruiting) (communications|e-?mails|messages|updates)\b"#)
    static let consent = Regex(#"\b(i )?(agree|consent|acknowledge|accept|certify|confirm|attest|understand)\b|\bhave read\b|privacy (policy|notice|statement)|terms (of|and) (use|conditions|service)"#)

    /// Consent boxes are checked (an application can't go without them); sign-ups for marketing, job alerts, texts and
    /// talent communities are declined unless the form requires them.
    static func consentOrSignup(_ f: FieldSpec, _ label: String) -> String? {
        // A list whose choices show only once it's opened (Paylocity's "permission to text you?"): plain Yes or No.
        let unread = f.options.isEmpty && (f.type == .combobox || f.type == .select)
        // An arbitration agreement is the person's own decision, never ticked for them.
        if Regex(#"arbitration"#).matches(label) { return nil }
        let yes = f.type == .checkbox || unread ? "Yes" : f.options.first {
            Regex(#"^(yes|i agree|agree|i consent|i accept|accept|i acknowledge|acknowledged?|i confirm|confirm(ed|ing)?|i understand|understood|i have read|i'?ve read)\b"#).matches(norm($0))
        }
        let no = f.type == .checkbox || unread ? "No" : f.options.first { Regex(#"^(no|i do not|i don't|decline)\b"#).matches(norm($0)) }
        if signup.matches(label) { return f.required && f.type == .checkbox ? "Yes" : no }
        if consent.matches(label) && !Regex(#"\?$|\b(are|have|do|did|will|were|is) you\b"#).matches(label) { return yes }
        return nil
    }

    /// "4 weeks after offer" as a date when the box wants one (a date box, "MM/DD/YYYY", "Start Date"): that long
    /// from today, written the way the box shows. Anything else as it is.
    static func startDate(_ raw: String, for f: FieldSpec, today: Date = Date()) -> String {
        let ph = f.placeholder.lowercased()
        let wantsDate = f.type == .date || Regex(#"\b(mm|dd)\b.{0,3}\b(dd|mm)\b.{0,3}\byy(yy)?\b|\byyyy\b.{0,3}\bmm\b"#).matches(ph)
            || Regex(#"\bdate\b"#).matches(norm(f.label))
        let v = raw.trimmed.lowercased()
        guard wantsDate, !Regex(#"\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{1,2}-\d{1,2}"#).matches(v) else { return raw }
        var days: Int?
        if let g = Regex(#"(\d+|one|two|three|four|six|eight)\s*(day|week|month)s?"#).firstGroups(v), let n = g[1], let unit = g[2] {
            let count = Int(n) ?? ["one": 1, "two": 2, "three": 3, "four": 4, "six": 6, "eight": 8][n] ?? 0
            days = count * (unit == "day" ? 1 : unit == "week" ? 7 : 30)
        } else if Regex(#"\b(immediately|asap|as soon as possible|right away|now)\b"#).matches(v) {
            days = 0
        }
        guard let days, let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: today) else { return raw }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = f.type == .date || ph.hasPrefix("yyyy") ? "yyyy-MM-dd" : ph.hasPrefix("dd") ? "dd/MM/yyyy" : "MM/dd/yyyy"
        return fmt.string(from: date)
    }

    /// Today, written the way the box shows ("MM/DD/YYYY" unless it says otherwise; a date box takes 2026-11-16).
    /// The day a notice period ("2 weeks", "1 month", "30 days", "Immediately") ends, counted from `now`.
    static func noticeEnds(_ notice: String, now: Date = Date()) -> Date? {
        let n = norm(notice)
        let cal = Calendar(identifier: .gregorian)
        if Regex(#"^(immediate(ly)?|none|0|now|asap|available now)$"#).matches(n) { return now }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "six": 6, "eight": 8, "a": 1]
        guard let g = Regex(#"^(\d+|one|two|three|four|six|eight|a)\s*(day|week|month)s?\b"#).firstGroups(n), let raw = g[1], let unit = g[2],
              let k = Int(raw) ?? words[raw] else { return nil }
        switch unit {
        case "day": return cal.date(byAdding: .day, value: k, to: now)
        case "week": return cal.date(byAdding: .day, value: 7 * k, to: now)
        default: return cal.date(byAdding: .month, value: k, to: now)
        }
    }

    static func today(for f: FieldSpec, now: Date = Date()) -> String {
        let ph = f.placeholder.lowercased()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = f.type == .date || ph.hasPrefix("yyyy") ? "yyyy-MM-dd" : ph.hasPrefix("dd") ? "dd/MM/yyyy" : "MM/dd/yyyy"
        return fmt.string(from: now)
    }

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    /// Year and month in a date as people write them: "2024-2026", "June 2026", "2026-06", "06/2026", "2022".
    static func dateParts(_ raw: String) -> (startYear: Int?, endYear: Int?, month: Int?) {
        let s = raw.lowercased()
        let years = Regex(#"(?<!\d)(19|20)\d\d(?!\d)"#, []).allMatches(s).compactMap(Int.init)
        var month: Int?
        if let i = months.firstIndex(where: { s.contains(String($0.prefix(3))) }) { month = i + 1 }
        if month == nil, let g = Regex(#"(?:^|\D)(?:(19|20)\d\d[-/.](0?[1-9]|1[0-2])|(0?[1-9]|1[0-2])[-/.](19|20)\d\d)(?:\D|$)"#, []).firstGroups(s) {
            month = Int(g[2] ?? g[3] ?? "")
        }
        return (years.first, years.last, month)
    }

    static func monthName(_ m: Int?) -> String? { m.map { months[$0 - 1].capitalized } }

    /// A whole date for a "Start date" / "End date" box in a job or school entry, written as the box wants it
    /// ("2022-01-01" in a date box, "01/2022" for "MM/YYYY", else "01/01/2022"). The profile often gives only the year
    /// ("2022"): then January. Always the 1st of the month.
    static func wholeDate(year: Int?, month: Int?, for f: FieldSpec) -> String? {
        guard let year, f.type == .text || f.type == .date else { return nil }
        let m = month ?? 1
        let ph = f.placeholder.lowercased().replacingOccurrences(of: " ", with: "")
        if f.type == .date || ph.hasPrefix("yyyy-mm-dd") { return String(format: "%04d-%02d-01", year, m) }
        if Regex(#"^yyyy[-/.]mm$"#).matches(ph) { return String(format: "%04d-%02d", year, m) }
        if Regex(#"^mm[-/.]yyyy$"#).matches(ph) { return String(format: "%02d/%04d", m, year) }
        if Regex(#"^mm[-/.]yy$"#).matches(ph) { return String(format: "%02d/%02d", m, year % 100) }
        if ph.hasPrefix("dd") { return String(format: "01/%02d/%04d", m, year) }
        return String(format: "%02d/01/%04d", m, year)
    }

    static let wholeDateLabel = Regex(#"^(start|end|from|to|graduation|completion)( date)?$"#)

    /// "Education › …" from the first school in the profile.
    static func education(_ p: Profile, _ f: FieldSpec, _ label: String) -> String? {
        guard let e = p.education.first else { return nil }
        let grad = dateParts(e.graduationDate), start = dateParts(e.startDate)
        let isStart = Regex(#"^(start|from)"#).matches(label), isEnd = Regex(#"^(end|to|graduation|completion)"#).matches(label)
        if Regex(schoolLabel).matches(label) { return nonEmpty(e.school) }
        if Regex(#"^degree"#).matches(label) { return nonEmpty(e.degree) }
        if Regex(#"discipline|field of study|^major"#).matches(label) { return nonEmpty(e.fieldOfStudy) }
        if label == "gpa" || label == "grade" { return nonEmpty(e.gpa) }
        // "I currently attend": whether the school's end is still to come.
        if Regex(#"^(i )?(currently|still) (attend|attending|studying|enrolled|pursuing)( here| this( degree)?)?$|^(i )?attend here$|^current(ly)?( attending)?$"#).matches(label) {
            guard let year = grad.endYear else { return nil }
            let now = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
            return yn(year > (now.year ?? 0) || (year == now.year && (grad.month ?? 12) >= (now.month ?? 1)))
        }
        if Regex(#"year$"#).matches(label) {
            if isStart { return (start.startYear ?? (grad.startYear != grad.endYear ? grad.startYear : nil)).map(String.init) }
            if isEnd { return grad.endYear.map(String.init) }
        }
        if Regex(#"month$"#).matches(label) {
            if isStart { return monthName(start.month) }
            if isEnd { return monthName(grad.month) }
        }
        if wholeDateLabel.matches(label) {
            if isStart { return wholeDate(year: start.startYear ?? (grad.startYear != grad.endYear ? grad.startYear : nil), month: start.month, for: f) }
            if isEnd { return wholeDate(year: grad.endYear, month: grad.month, for: f) }
        }
        return nil
    }

    /// "Work experience › …" from the most recent job in the profile.
    static func work(_ p: Profile, _ f: FieldSpec, _ label: String, today: Date = Date()) -> String? {
        guard let r = p.workHistory.first else { return nil }
        let isStart = Regex(#"^(start|from)"#).matches(label), isEnd = Regex(#"^(end|to)"#).matches(label)
        if Regex(#"^(company|employer|organi[sz]ation)( name)?$"#).matches(label) { return nonEmpty(r.company) }
        if Regex(#"^((job |position )?title|position|role)$"#).matches(label) { return nonEmpty(r.title) }
        if Regex(#"^(location|city)$"#).matches(label) { return nonEmpty(r.location) }
        if Regex(#"current|work here|still working"#).matches(label) { return yn(r.isCurrent) }
        if Regex(#"^(description|responsibilities|summary)$"#).matches(label) { return r.bullets.isEmpty ? nil : r.bullets.joined(separator: "\n") }
        // A current job has no end date (its "current" box says so); where one is required anyway, this month's.
        if isEnd && r.isCurrent {
            guard f.required, wholeDateLabel.matches(label) else { return nil }
            let now = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: today)
            return wholeDate(year: now.year, month: now.month, for: f)
        }
        let d = dateParts(isStart ? r.startDate : r.endDate)
        if Regex(#"year$"#).matches(label) { return (isStart ? d.startYear : d.endYear).map(String.init) }
        if Regex(#"month$"#).matches(label) { return monthName(d.month) }
        if wholeDateLabel.matches(label) { return wholeDate(year: isStart ? d.startYear : d.endYear, month: d.month, for: f) }
        return nil
    }
}

/// Questions the AI must never answer on its own: they need the user's own word (answered once, then remembered).
let neverGuess = Regex(
    #"\brate (your|yourself)|on a scale|scale of|\b1 ?(-|to) ?(5|10)\b|proficiency level|"#
        + #"convicted|felony|criminal|misdemeanor|background check|drug (test|screen)|"#
        + #"current (salary|compensation|base)|salary history|previous salary|"#
        + #"references?\b|referred by|employee referral|"#
        + #"non-?compete|been terminated|fired from|disciplinary"#)

private let yearsWord = Regex(#"\byears?\b|\bhow long\b"#)
private let skillContext = Regex(#"experience|\b(with|in|using|of|worked|working|used|doing)\b"#)
private let notASkill = Regex(#"commute|minutes|hours|days|weeks|months|notice|relocat|start|lived|reside|address|age\b|old are you"#)

/// "How many years of Rust do you have?" — a number the AI must never guess when the skill isn't in the profile.
/// (Version 0.3 also caught questions like "How long is your commute in minutes?" here, so they were never answered.)
func asksYearsOfSkill(_ f: FieldSpec) -> Bool {
    guard f.type != .textarea else { return false }
    let n = norm(f.label)
    return yearsWord.matches(n) && skillContext.matches(n) && !notASkill.matches(n)
}

/// The skill a "years of X" question asks about, e.g. "How many years of experience do you have with Rust?" -> "Rust".
public func skillInYearsQuestion(_ label: String) -> String? {
    let patterns = [
        #"years?(?: of)?(?: professional| hands-on| work| relevant| industry)?(?: experience)?(?: do you have)? (?:with|in|using|working with) (.+?)(?: experience)?(?: do you have)?\s*\??$"#,
        #"years? of (?:professional |hands-on |work )?(.+?) experience"#,
        #"years? have you (?:worked with|used|been using|worked in|been working with) (.+?)\s*\??$"#,
        #"(.+?) \(years(?: of experience)?\)$"#,
    ]
    let text = label.replacingOccurrences(of: "*", with: "").trimmed
    for p in patterns {
        if let g = Regex(p).firstGroups(text), let raw = g[1] {
            var skill = raw.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "?.:"))
            for prefix in ["the ", "a ", "an "] where skill.lowercased().hasPrefix(prefix) { skill = String(skill.dropFirst(prefix.count)) }
            let words = skill.split(separator: " ")
            if !skill.isEmpty, words.count <= 4, !["experience", "work", "it"].contains(skill.lowercased()) { return skill }
        }
    }
    return nil
}

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
        + #"^(street|address( line 1)?|mailing address)$|^city$|^(state|province)( ?/ ?province)?$|^(zip|postal)( ?/ ?postal)?( code)?$|^country( of residence)?$|"#
        + #"linkedin|github|portfolio|^website$"#)

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
        guard Regex(#"linkedin|indeed|glassdoor|ziprecruiter|dice|monster|handshake|wellfound|built ?in"#).matches(norm(source)) else { return nil }
        for kind in [#"job ?boards?|job (site|search|posting)|online job|internet job|career (site|website)"#, #"social (media|network)"#, #"^online$|^internet$"#, #"^other\b"#] {
            if let o = options.first(where: { Regex(kind).matches(norm($0)) }) { return o }
        }
        return nil
    }

    static func inUS(_ p: Profile) -> Bool {
        Regex(#"^(united states( of america)?|u\.?s\.?(a\.?)?|america)$"#).matches(norm(p.personal.address.country))
    }

    /// "Have you previously been employed by Booz Allen?", "Do you currently work or have you previously worked … for
    /// Comcast or any Company within the Comcast Family?": from the work history. Not questions about relatives or
    /// friends who work there.
    static func formerEmployee(_ p: Profile, _ f: FieldSpec, company: String) -> String? {
        guard [.radio, .select, .combobox, .checkbox].contains(f.type) || f.options.count == 2 else { return nil }
        let label = norm(f.label)
        guard Regex(#"\b(previously|ever|formerly|before|prior|former|past|currently work or have you)\b"#).matches(label),
              Regex(#"\b(employ(ed|ee|ment)|work(ed)?|contractor|intern(ed)?)\b"#).matches(label),
              !Regex(#"relative|family member|spouse|friend|know anyone|related to|referr"#).matches(label) else { return nil }
        let skip: Set<String> = ["inc", "llc", "corp", "corporation", "company", "co", "the", "group", "ltd", "limited", "holdings", "technologies", "services"]
        let words = norm(company).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !skip.contains($0) }
        let thisOne = Regex(#"\bthis (organi[sz]ation|company|employer|firm)\b|\bour (company|organi[sz]ation)\b|\b(with|for) us\b|\bworked here\b"#).matches(label)
        guard let name = words.first, thisOne || Regex("\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b").matches(label) else { return nil }
        let worked = p.workHistory.contains { Regex("\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b").matches(norm($0.company)) }
        return yn(worked)
    }

    static func isUSCitizen(_ p: Profile) -> Bool {
        let status = "\(p.workAuthorization.visaStatus) \(p.workAuthorization.citizenship)".lowercased()
        return (status.contains("citizen") && !status.contains("non")) || p.workAuthorization.citizenship.lowercased().contains("united states")
    }

    static let rules: [Rule] = {
        func r(_ pattern: String, _ fn: @escaping (Profile, FieldSpec) -> String?) -> Rule { (Regex(pattern), fn) }
        return [
            r(#"phone (device )?type|type of phone"#) { _, _ in "Mobile" },
            r(degreeQuestion) { p, f in hasDegree(p, asked: norm(f.label)).map(yn) },
            r(#"country (phone )?code|phone (country )?code|dialing code"#) { p, _ in nonEmpty(p.personal.phoneCountryCode) },
            r(#"time ?zone"#) { p, _ in TimeZones.of(p) },
            r(#"\bpreferred (first )?name\b|\bnickname\b"#) { p, _ in nonEmpty(p.personal.preferredName) ?? nonEmpty(p.personal.firstName) },
            r(#"\bfirst name\b|\bgiven name\b"#) { p, _ in nonEmpty(p.personal.firstName) },
            r(#"\blast name\b|\bfamily name\b|\bsurname\b"#) { p, _ in nonEmpty(p.personal.lastName) },
            r(#"^(your )?(full |legal |full legal )?name$|^candidate name$"#) { p, _ in nonEmpty(p.personal.fullName) },
            r(#"e-?mail"#) { p, _ in nonEmpty(p.personal.email) },
            r(#"\b(phone|mobile|cell)( number)?\b(?!.*\bext(ension)?\b)"#) { p, f in extensionLabel.matches(norm(f.label)) ? nil : nonEmpty(p.personal.phone) },
            r(#"linkedin"#) { p, _ in link(p.personal.linkedin) },
            r(#"github"#) { p, _ in link(p.personal.github) },
            r(#"portfolio|personal (web)?site|^website$|^other website"#) { p, _ in link(p.personal.portfolio) ?? link(p.personal.github) },
            r(#"(street|address line 1|^address$|mailing address)"#) { p, _ in nonEmpty(p.personal.address.street) },
            // LinkedIn's "Location (city)" suggests "Springfield, Illinois, United States" as you type: the city with its
            // state picks the right Springfield.
            r(#"^location \(city\)$"#) { p, _ in nonEmpty(p.personal.displayLocation) },
            r(#"^city$|\bcity\b(?!.*(willing|relocat|prefer|like to))"#) { p, _ in nonEmpty(p.personal.address.city) },
            r(#"^(state|province)( ?/ ?(province|region|state)| or province)?( (select|choose) (a|an|your|the) (state|province))?$|state ?/ ?province|state or province|^state of residence$"#) { p, _ in nonEmpty(p.personal.address.state) },
            r(#"zip|postal"#) { p, _ in nonEmpty(p.personal.address.postalCode) },
            r(#"^country$|country of residence|country/region"#) { p, _ in nonEmpty(p.personal.address.country) },
            r(#"^(current )?location$|where are you (currently )?(located|based)|^location \(city\)"#) { p, _ in nonEmpty(p.personal.location) ?? nonEmpty(p.personal.displayLocation) },
            r(#"(located|living|residing|reside|based) in the (united states|u\.? ?s\.?( ?a\.?)?)\b|(live|reside) in the (united states|u\.? ?s\.?)\b"#) { p, _ in
                p.personal.address.country.isEmpty ? nil : yn(inUS(p))
            },
            r(#"(legally )?authori[sz]ed to work|eligible to work|right to work|work authori[sz]ation"#) { p, _ in yn(p.workAuthorization.authorizedToWork) },
            r(#"sponsor"#) { p, _ in yn(p.workAuthorization.requiresSponsorship) },
            r(#"are you (a )?(u\.?s\.?|united states) citizen"#) { p, _ in yn(isUSCitizen(p)) },
            r(#"security clearance|active clearance"#) { p, _ in nonEmpty(p.workAuthorization.securityClearance) },
            r(#"relocat"#) { p, _ in yn(p.preferences.willingToRelocate) },
            r(#"notice period"#) { p, _ in nonEmpty(p.preferences.noticePeriod) },
            r(#"earliest.*start|when can you start|available to start|availability to start|desired start date"#) { p, f in
                nonEmpty(p.preferences.earliestStartDate).map { startDate($0, for: f) }
            },
            r(#"(18|eighteen) years|at least 18|over the age of"#) { p, _ in yn(p.preferences.over18) },
            r(#"how did you (hear|find|learn)|where did you (hear|find|see|learn)|referral source|^source$"#) { p, f in
                nonEmpty(p.preferences.howDidYouHear).map { sourceOption($0, f.options) ?? $0 }
            },
            r(#"(desired|expected|target) (salary|compensation|pay)|salary expectation|compensation expectation|^salary$"#) { p, _ in p.compensation.desiredBase.map(String.init) },
            r(#"(current|most recent) (company|employer)|^company$|^employer$"#) { p, _ in p.currentRole.flatMap { nonEmpty($0.company) } },
            r(#"(current|most recent) (job )?(title|position|role)"#) { p, _ in p.currentRole.flatMap { nonEmpty($0.title) } },
            r(schoolLabel) { p, _ in p.education.first.flatMap { nonEmpty($0.school) } },
            r(#"field of study|^major$|discipline"#) { p, _ in p.education.first.flatMap { nonEmpty($0.fieldOfStudy) } },
            r(#"\bgender\b"#) { p, _ in eeo(p.eeo.gender) },
            r(#"hispanic|latino"#) { p, _ in eeo(p.eeo.hispanicOrLatino) },
            r(#"\brace\b|ethnicit"#) { p, _ in eeo(p.eeo.ethnicity) },
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

    /// "Middle name", "Middle initial", "M.I.": the profile has none, so these are never guessed.
    static let middleLabel = Regex(#"^m\.? ?i\.?$|\bmiddle (name|initial)s?\b|^middle$|\bsecond(ary)? (last )?name\b|\bsecond surname\b|\bmaternal (last )?name\b"#)

    /// A phone extension: the profile has none (Blue Yonder's got the whole number).
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
        #"(how many |total )?(years of )?(total |professional |work |relevant |industry |overall )?(work )?(years of )?experience( do you have)?( in total)?( \(years\))?"#)

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
        if genericExperience.fullMatch(n), n.contains("years"), let total = p.totalYears { return String(Int(total.rounded())) }
        return nil
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
        if [.checkbox, .radio, .select, .combobox, .checkboxGroup].contains(f.type), let choice = consentOrSignup(f, label) { return choice }
        if FieldSpec.ambiguous.matches(label) {
            switch f.section {
            case "Education": return education(p, f, label)
            case "Work experience": return work(p, f, label)
            case "References", "Emergency contact", "Referral": return nil  // someone else's details, never the person's own
            default: break
            }
        }
        for (pattern, fn) in rules where pattern.matches(label) {
            return fn(p, f)  // a matching rule without data stops here
        }
        return nil
    }

    // MARK: sections

    static let signup = Regex(#"(text|sms) messag|\bsms\b|newsletter|marketing|promotional|job alerts?|talent (community|network|pool)|subscribe|"#
                              + #"similar (jobs|roles|opportunities)|future (job )?opportunit|keep me (informed|updated)|contact me about|join .{0,40}communit"#)
    static let consent = Regex(#"\b(i )?(agree|consent|acknowledge|accept|certify|confirm|attest|understand)\b|\bhave read\b|privacy (policy|notice|statement)|terms (of|and) (use|conditions|service)"#)

    /// Consent boxes are checked (an application can't go without them); sign-ups for marketing, job alerts, texts and
    /// talent communities are declined unless the form requires them.
    static func consentOrSignup(_ f: FieldSpec, _ label: String) -> String? {
        // A list whose choices show only once it's opened (Paylocity's "permission to text you?"): plain Yes or No.
        let unread = f.options.isEmpty && (f.type == .combobox || f.type == .select)
        let yes = f.type == .checkbox || unread ? "Yes" : f.options.first { Regex(#"^(yes|i agree|agree|i consent|i accept|accept|i acknowledge)\b"#).matches(norm($0)) }
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

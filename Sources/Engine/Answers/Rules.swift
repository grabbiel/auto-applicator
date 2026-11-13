import Foundation

/// Answers that come straight from the profile, without the AI. Order matters: specific patterns first, and a rule that
/// matches but has no data stops the search (so "Portfolio" never falls through to a broader rule).
enum ProfileRules {
    typealias Rule = (Regex, (Profile, FieldSpec) -> String?)

    static func yn(_ v: Bool) -> String { v ? "Yes" : "No" }
    static func eeo(_ v: String) -> String { v.isEmpty ? declineToSelfIdentify : v }
    static func nonEmpty(_ s: String) -> String? { s.trimmed.isEmpty ? nil : s }

    static func isUSCitizen(_ p: Profile) -> Bool {
        let status = "\(p.workAuthorization.visaStatus) \(p.workAuthorization.citizenship)".lowercased()
        return (status.contains("citizen") && !status.contains("non")) || p.workAuthorization.citizenship.lowercased().contains("united states")
    }

    static let rules: [Rule] = {
        func r(_ pattern: String, _ fn: @escaping (Profile, FieldSpec) -> String?) -> Rule { (Regex(pattern), fn) }
        return [
            r(#"phone (device )?type|type of phone"#) { _, _ in "Mobile" },
            r(#"country (phone )?code|phone (country )?code|dialing code"#) { p, _ in nonEmpty(p.personal.phoneCountryCode) },
            r(#"\bpreferred (first )?name\b|\bnickname\b"#) { p, _ in nonEmpty(p.personal.preferredName) ?? nonEmpty(p.personal.firstName) },
            r(#"\bfirst name\b|\bgiven name\b"#) { p, _ in nonEmpty(p.personal.firstName) },
            r(#"\blast name\b|\bfamily name\b|\bsurname\b"#) { p, _ in nonEmpty(p.personal.lastName) },
            r(#"^(your )?(full |legal |full legal )?name$|^candidate name$"#) { p, _ in nonEmpty(p.personal.fullName) },
            r(#"e-?mail"#) { p, _ in nonEmpty(p.personal.email) },
            r(#"\b(phone|mobile|cell)( number)?\b"#) { p, _ in nonEmpty(p.personal.phone) },
            r(#"linkedin"#) { p, _ in nonEmpty(p.personal.linkedin) },
            r(#"github"#) { p, _ in nonEmpty(p.personal.github) },
            r(#"portfolio|personal (web)?site|^website$|^other website"#) { p, _ in nonEmpty(p.personal.portfolio) ?? nonEmpty(p.personal.github) },
            r(#"(street|address line 1|^address$|mailing address)"#) { p, _ in nonEmpty(p.personal.address.street) },
            r(#"^city$|\bcity\b(?!.*(willing|relocat|prefer|like to))"#) { p, _ in nonEmpty(p.personal.address.city) },
            r(#"^state$|state/province|^province$|state or province"#) { p, _ in nonEmpty(p.personal.address.state) },
            r(#"zip|postal"#) { p, _ in nonEmpty(p.personal.address.postalCode) },
            r(#"^country$|country of residence|country/region"#) { p, _ in nonEmpty(p.personal.address.country) },
            r(#"^(current )?location$|where are you (currently )?(located|based)|^location \(city\)"#) { p, _ in nonEmpty(p.personal.location) ?? nonEmpty(p.personal.displayLocation) },
            r(#"(legally )?authori[sz]ed to work|eligible to work|right to work|work authori[sz]ation"#) { p, _ in yn(p.workAuthorization.authorizedToWork) },
            r(#"sponsor"#) { p, _ in yn(p.workAuthorization.requiresSponsorship) },
            r(#"are you (a )?(u\.?s\.?|united states) citizen"#) { p, _ in yn(isUSCitizen(p)) },
            r(#"security clearance|active clearance"#) { p, _ in nonEmpty(p.workAuthorization.securityClearance) },
            r(#"relocat"#) { p, _ in yn(p.preferences.willingToRelocate) },
            r(#"notice period"#) { p, _ in nonEmpty(p.preferences.noticePeriod) },
            r(#"earliest.*start|when can you start|available to start|availability to start|desired start date"#) { p, _ in nonEmpty(p.preferences.earliestStartDate) },
            r(#"(18|eighteen) years|at least 18|over the age of"#) { p, _ in yn(p.preferences.over18) },
            r(#"how did you (hear|find|learn)|where did you (hear|find|see|learn)|referral source|^source$"#) { p, _ in nonEmpty(p.preferences.howDidYouHear) },
            r(#"(desired|expected|target) (salary|compensation|pay)|salary expectation|compensation expectation|^salary$"#) { p, _ in p.compensation.desiredBase.map(String.init) },
            r(#"(current|most recent) (company|employer)|^company$|^employer$"#) { p, _ in p.currentRole.flatMap { nonEmpty($0.company) } },
            r(#"(current|most recent) (job )?(title|position|role)"#) { p, _ in p.currentRole.flatMap { nonEmpty($0.title) } },
            r(#"^(school|university|college|institution)( name)?$"#) { p, _ in p.education.first.flatMap { nonEmpty($0.school) } },
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
            if let v = keys[label] { return v }
            if let close = Difflib.closeMatch(label, Array(keys.keys), cutoff: 0.9) { return keys[close] }
        }
        for (pattern, fn) in rules where pattern.matches(label) {
            return fn(p, f)  // a matching rule without data stops here
        }
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

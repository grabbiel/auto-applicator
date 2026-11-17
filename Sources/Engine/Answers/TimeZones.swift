import Foundation

/// Time zones: the person's own, from the profile's address, and the names a list may give it.
enum TimeZones {
    /// The main zone of each US state (the one most of it uses).
    static let usStates: [String: String] = {
        var z: [String: String] = [:]
        for s in ["CT", "DE", "DC", "FL", "GA", "IN", "KY", "ME", "MD", "MA", "MI", "NH", "NJ", "NY", "NC", "OH", "PA", "RI", "SC", "VT", "VA", "WV"] {
            z[s] = "America/New_York"
        }
        for s in ["AL", "AR", "IL", "IA", "KS", "LA", "MN", "MS", "MO", "NE", "ND", "OK", "SD", "TN", "TX", "WI"] { z[s] = "America/Chicago" }
        for s in ["CO", "ID", "MT", "NM", "UT", "WY"] { z[s] = "America/Denver" }
        for s in ["CA", "NV", "OR", "WA"] { z[s] = "America/Los_Angeles" }
        z["AZ"] = "America/Phoenix"
        z["AK"] = "America/Anchorage"
        z["HI"] = "Pacific/Honolulu"
        return z
    }()

    /// Countries with one zone (or one most people use).
    static let countries: [String: String] = [
        "peru": "America/Lima", "colombia": "America/Bogota", "ecuador": "America/Guayaquil", "chile": "America/Santiago",
        "argentina": "America/Argentina/Buenos_Aires", "mexico": "America/Mexico_City", "united kingdom": "Europe/London",
        "ireland": "Europe/Dublin", "spain": "Europe/Madrid", "france": "Europe/Paris", "germany": "Europe/Berlin", "italy": "Europe/Rome",
        "netherlands": "Europe/Amsterdam", "poland": "Europe/Warsaw", "portugal": "Europe/Lisbon", "india": "Asia/Kolkata",
        "japan": "Asia/Tokyo", "singapore": "Asia/Singapore", "philippines": "Asia/Manila", "south korea": "Asia/Seoul",
        "costa rica": "America/Costa_Rica", "guatemala": "America/Guatemala", "venezuela": "America/Caracas", "bolivia": "America/La_Paz",
        "uruguay": "America/Montevideo", "paraguay": "America/Asuncion", "panama": "America/Panama", "dominican republic": "America/Santo_Domingo",
    ]

    /// The zone of the profile's address ("America/Los_Angeles" for Oregon); nil when it can't tell.
    static func of(_ p: Profile) -> String? {
        let a = p.personal.address
        let country = a.country.trimmed.lowercased()
        if country.isEmpty || ["united states", "united states of america", "usa", "us", "u.s."].contains(country) {
            let state = a.state.trimmed
            let code = state.count == 2 ? state.uppercased() : LinkedIn.usStates.first { $0.value.lowercased() == state.lowercased() }?.key
            if let code, let zone = usStates[code] { return zone }
            if !country.isEmpty { return nil }
        }
        return countries[country]
    }

    /// Older names some lists still use.
    static let aliases = ["America/New_York": "US/Eastern", "America/Chicago": "US/Central", "America/Denver": "US/Mountain",
                          "America/Phoenix": "US/Arizona", "America/Los_Angeles": "US/Pacific", "America/Anchorage": "US/Alaska",
                          "Pacific/Honolulu": "US/Hawaii", "Asia/Kolkata": "Asia/Calcutta"]

    /// The option naming the zone `answer` (an identifier such as "America/Los_Angeles") in a list's own words:
    /// the identifier or its old alias, "Pacific Time (US & Canada)", "PST", or "(GMT-08:00) …".
    static func match(_ answer: String, _ options: [String]) -> String? {
        guard answer.contains("/"), let tz = TimeZone(identifier: answer.trimmed) else { return nil }
        let id = tz.identifier
        let lower = options.map { $0.lowercased() }
        let ids = [id, id.replacingOccurrences(of: "_", with: " "), aliases[id]].compactMap { $0?.lowercased() }
        if let i = lower.firstIndex(where: { ids.contains($0) }) { return options[i] }
        let en = Locale(identifier: "en_US")
        let names = [tz.localizedName(for: .generic, locale: en), tz.localizedName(for: .standard, locale: en)].compactMap { $0?.lowercased() }
        if let i = lower.firstIndex(where: { o in names.contains { o.contains($0) } }) { return options[i] }
        let january = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: tz, year: 2026, month: 1, day: 15).date ?? Date()
        if let abbr = tz.abbreviation(for: january)?.lowercased(), abbr.count >= 3, !abbr.hasPrefix("gmt") {
            if let i = lower.firstIndex(where: { $0 == abbr || Regex(#"(^|[^a-z])"# + abbr + #"([^a-z]|$)"#).matches($0) }) { return options[i] }
        }
        let seconds = tz.secondsFromGMT(for: january)
        let sign = seconds < 0 ? "-" : "+", h = abs(seconds) / 3600, m = (abs(seconds) % 3600) / 60
        let offsets = [String(format: "%@%02d:%02d", sign, h, m), String(format: "%@%d:%02d", sign, h, m), m == 0 ? "\(sign)\(h)" : nil].compactMap { $0 }
        for prefix in ["gmt", "utc"] {
            for o in offsets {
                let want = prefix + o
                if let i = lower.firstIndex(where: { $0.replacingOccurrences(of: " ", with: "").contains(want) && !$0.replacingOccurrences(of: " ", with: "").contains(want + "0") }) {
                    return options[i]
                }
            }
        }
        return nil
    }
}

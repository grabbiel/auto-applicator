import Foundation

/// Mail providers the app knows, with the short "how to get an app password" guide shown in onboarding.
public enum EmailProviders {
    public struct Guide: Sendable {
        public var name: String
        public var host: String
        /// Steps in Markdown (links open in the browser).
        public var steps: [String]
        public var link: URL?
    }

    static let hosts: [String: String] = [
        "gmail.com": "imap.gmail.com", "googlemail.com": "imap.gmail.com",
        "outlook.com": "outlook.office365.com", "hotmail.com": "outlook.office365.com", "live.com": "outlook.office365.com",
        "msn.com": "outlook.office365.com",
        "icloud.com": "imap.mail.me.com", "me.com": "imap.mail.me.com", "mac.com": "imap.mail.me.com",
        "yahoo.com": "imap.mail.yahoo.com", "ymail.com": "imap.mail.yahoo.com",
        "aol.com": "imap.aol.com", "fastmail.com": "imap.fastmail.com", "proton.me": "127.0.0.1",
    ]

    public static func domain(of address: String) -> String {
        String(address.split(separator: "@").last ?? "").lowercased().trimmed
    }

    public static func host(for address: String) -> String? {
        hosts[domain(of: address)]
    }

    public static func guide(for address: String) -> Guide? {
        switch domain(of: address) {
        case "gmail.com", "googlemail.com":
            return Guide(name: "Gmail", host: "imap.gmail.com", steps: [
                "Make sure **2-Step Verification** is on for your Google account.",
                "Open **[Google App Passwords](https://myaccount.google.com/apppasswords)**.",
                "Type **Auto Applicator** as the name and press **Create**.",
                "Copy the 16-letter password into the box below.",
            ], link: URL(string: "https://myaccount.google.com/apppasswords"))
        case "icloud.com", "me.com", "mac.com":
            return Guide(name: "iCloud Mail", host: "imap.mail.me.com", steps: [
                "Sign in at **[account.apple.com](https://account.apple.com)**.",
                "Choose **Sign-In and Security › App-Specific Passwords**.",
                "Add one called **Auto Applicator**.",
                "Copy the password into the box below.",
            ], link: URL(string: "https://account.apple.com"))
        case "yahoo.com", "ymail.com":
            return Guide(name: "Yahoo Mail", host: "imap.mail.yahoo.com", steps: [
                "Open **[Account security](https://login.yahoo.com/account/security)**.",
                "Choose **Generate app password** and name it **Auto Applicator**.",
                "Copy the password into the box below.",
            ], link: URL(string: "https://login.yahoo.com/account/security"))
        case "outlook.com", "hotmail.com", "live.com", "msn.com":
            return Guide(name: "Outlook.com", host: "outlook.office365.com", steps: [
                "Turn on **two-step verification** at **[account.microsoft.com/security](https://account.microsoft.com/security)**.",
                "Create an **app password** there.",
                "Copy it into the box below. (Microsoft blocks this for some accounts — if the test fails, choose **Skip**.)",
            ], link: URL(string: "https://account.microsoft.com/security"))
        case "aol.com":
            return Guide(name: "AOL Mail", host: "imap.aol.com", steps: [
                "Open **[Account security](https://login.aol.com/account/security)**.",
                "Choose **Generate app password** and copy it below.",
            ], link: URL(string: "https://login.aol.com/account/security"))
        case "fastmail.com":
            return Guide(name: "Fastmail", host: "imap.fastmail.com", steps: [
                "In Fastmail, open **Settings › Privacy & Security › Integrations**.",
                "Create a **new app password** with **IMAP** access and copy it below.",
            ], link: URL(string: "https://app.fastmail.com/settings/security/integrations"))
        default:
            return nil
        }
    }
}

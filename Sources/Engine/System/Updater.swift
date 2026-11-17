import CoreServices
import CryptoKit
import Foundation
import Security

/// What a release offers: `update.json`, published beside the disk image (scripts/make_update_manifest.swift).
public struct UpdateInfo: Codable, Equatable, Sendable {
    public var version: String
    /// The commit count it was built from (CFBundleVersion), for the record.
    public var build: Int?
    /// The disk image.
    public var url: URL
    public var sha256: String
    public var size: Int
    public var minimumSystemVersion: String?
    /// The release page: what's new, in full.
    public var page: URL?
    /// What's new, a line each (the titles of the pull requests it brings).
    public var notes: [String]?

    public init(version: String, build: Int? = nil, url: URL, sha256: String, size: Int, minimumSystemVersion: String? = nil,
                page: URL? = nil, notes: [String]? = nil) {
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minimumSystemVersion = minimumSystemVersion
        self.page = page
        self.notes = notes
    }
}

public enum UpdateError: LocalizedError, Equatable {
    /// The release's details couldn't be read.
    case feed(String)
    case download(String)
    /// What arrived isn't what the release describes (size, checksum, app, version or signature).
    case damaged(String)
    /// The app can't be replaced where it is; the disk image can still be opened and dragged over by hand.
    case cantReplace(String)

    public var errorDescription: String? {
        switch self {
        case .feed(let why): "Couldn't check for a new version: \(why)"
        case .download(let why): "Couldn't download the new version: \(why)"
        case .damaged(let why): "The download didn't check out (\(why)), so it wasn't installed."
        case .cantReplace(let why): why
        }
    }
}

/// In-app updates from the GitHub releases (README › Updates). The app reads the newest release's `update.json`,
/// downloads its disk image, checks it is exactly that file, copies the app out next to the installed one, and checks
/// that copy: the same app, the promised version, an intact signature (and, once releases are signed with a Developer
/// ID, the same developer). Installing swaps the two folders, so the old app stays whole until the new one is in place.
/// Everything comes over HTTPS from this repository's releases: the same source as downloading the disk image by hand.
public enum Updater {
    public static let defaultFeed = URL(string: "https://github.com/grabbiel/auto-applicator/releases/latest/download/update.json")!
    /// Disk images only ever come from this repository's releases (unless AA_UPDATE_FEED names another feed).
    static let releaseDownloads = "https://github.com/grabbiel/auto-applicator/releases/download/"

    /// AA_UPDATE_FEED replaces the feed: a file:// or https:// update.json, to try a release before publishing it.
    public static var feed: URL {
        if let text = ProcessInfo.processInfo.environment["AA_UPDATE_FEED"], !text.isEmpty, let url = URL(string: text) { return url }
        return defaultFeed
    }

    /// "1.10.0" is newer than "1.9.2"; a missing part counts as 0 ("1.2" == "1.2.0").
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) -> [Int] in s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - checking

    /// The release on offer when it is newer than `current` and runs on this Mac; nil when there's nothing to install
    /// (also when the newest release has no update.json yet).
    public static func check(current: String, feed: URL = Updater.feed,
                             system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) async throws -> UpdateInfo? {
        let data: Data
        if feed.isFileURL {
            guard let d = try? Data(contentsOf: feed) else { return nil }
            data = d
        } else {
            let (d, response) = try await fetch(feed)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return nil }
            guard status == 200 else { throw UpdateError.feed("GitHub answered \(status).") }
            data = d
        }
        guard let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else {
            throw UpdateError.feed("the release's update.json isn't readable.")
        }
        guard isNewer(info.version, than: current) else { return nil }
        if let minimum = info.minimumSystemVersion {
            let have = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            if isNewer(minimum, than: have) {
                Log.info("Version \(info.version) needs macOS \(minimum); this Mac has \(have)")
                return nil
            }
        }
        guard info.sha256.count == 64, info.sha256.allSatisfy(\.isHexDigit), info.size > 0 else {
            throw UpdateError.feed("the release's update.json is incomplete.")
        }
        guard accepts(info.url, from: feed) else { throw UpdateError.feed("its disk image isn't on this app's releases page.") }
        return info
    }

    /// The disk image must be one of this repository's release downloads (another feed, set for testing, may name
    /// any https:// or file:// one).
    static func accepts(_ url: URL, from feed: URL) -> Bool {
        if url.absoluteString.hasPrefix(releaseDownloads) && url.scheme == "https" { return true }
        return feed != defaultFeed && (url.scheme == "https" || url.isFileURL)
    }

    private static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("AutoApplicator-updater", forHTTPHeaderField: "User-Agent")
        do {
            return try await session.data(for: request)
        } catch {
            throw UpdateError.feed(error.localizedDescription)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - downloading

    /// Downloads the disk image into `folder` and checks it is exactly the one the release describes.
    public static func download(_ info: UpdateInfo, into folder: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("AutoApplicator-\(info.version).dmg")
        try? fm.removeItem(at: dest)
        if info.url.isFileURL {
            try fm.copyItem(at: info.url, to: dest)
        } else {
            let tmp: URL, response: URLResponse
            do {
                (tmp, response) = try await session.download(for: URLRequest(url: info.url, timeoutInterval: 60))
            } catch {
                throw UpdateError.download(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? fm.removeItem(at: tmp)
                throw UpdateError.download("GitHub answered \(status).")
            }
            try fm.moveItem(at: tmp, to: dest)
        }
        do {
            try checkFile(dest, size: info.size, sha256: info.sha256)
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
        return dest
    }

    static func checkFile(_ url: URL, size: Int, sha256: String) throws {
        let actual = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? -1
        guard actual == size else { throw UpdateError.damaged("\(actual) bytes, not \(size)") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw UpdateError.damaged("unreadable") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw UpdateError.damaged("its checksum differs") }
    }

    // MARK: - staging

    /// Copies the new app out of the disk image to a folder on the same disk as `installed` (so installing is a
    /// rename) and checks the copy against `installed`. Returns the copy.
    public static func stage(dmg: URL, info: UpdateInfo, installed: URL) throws -> URL {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        let mount = fm.temporaryDirectory.appendingPathComponent("aa-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            try? fm.removeItem(at: mount)
        }
        do {
            try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path, dmg.path])
        } catch {
            throw UpdateError.damaged("the disk image doesn't open")
        }
        let apps = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first(where: { $0.lastPathComponent == installed.lastPathComponent }) ?? apps.first else {
            throw UpdateError.damaged("no app in the disk image")
        }
        let staged = work.appendingPathComponent(installed.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: staged)
        do {
            try run("/usr/bin/ditto", [app.path, staged.path])
        } catch {
            throw UpdateError.download("couldn't copy the app out of the disk image")
        }
        do {
            try verify(staged, version: info.version, like: installed)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
        return staged
    }

    /// The same app as `installed` (bundle identifier), the promised version, and a signature that checks out; when
    /// `installed` is signed by a developer (a Developer ID), the new one must be signed by the same developer.
    static func verify(_ app: URL, version: String, like installed: URL) throws {
        guard let new = infoPlist(app), let old = infoPlist(installed) else {
            throw UpdateError.damaged("not an app")
        }
        let id = old["CFBundleIdentifier"] as? String
        guard id != nil, new["CFBundleIdentifier"] as? String == id else { throw UpdateError.damaged("another app") }
        guard new["CFBundleShortVersionString"] as? String == version else { throw UpdateError.damaged("not version \(version)") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.damaged("unsigned")
        }
        var requirement: SecRequirement?
        if let team = teamIdentifier(of: installed), let id {
            let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
            SecRequirementCreateWithString(text as CFString, [], &requirement)
            guard requirement != nil else { throw UpdateError.damaged("its developer couldn't be checked") }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.damaged(status == errSecCSReqFailed ? "signed by another developer" : "its signature is broken (\(status))")
        }
    }

    /// Read from the file each time (Bundle caches by path, and the folder at a path changes when an update lands).
    static func infoPlist(_ app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    /// The developer team that signed an app (nil for an ad-hoc signature).
    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - installing

    /// Why the app at `installed` can't replace itself, or nil when it can.
    public static func cantReplace(_ installed: URL) -> String? {
        let readOnly = (try? installed.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        if installed.path.contains("/AppTranslocation/") || readOnly {
            return "Auto Applicator is running from the disk image or a download folder. Drag it to your Applications folder, open it from there, and it can update itself."
        }
        if !FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) {
            return "This Mac account can't change apps in \(installed.deletingLastPathComponent().path). Open the new disk image and drag the app over the old one."
        }
        return nil
    }

    /// Puts the staged app where `installed` is. The two folders swap places in one step, then the old one is
    /// removed; if a swap isn't possible, the old app is moved aside first and put back should the move fail.
    public static func install(staged: URL, over installed: URL) throws {
        if let why = cantReplace(installed) { throw UpdateError.cantReplace(why) }
        let fm = FileManager.default
        if renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 {
            // `staged` now holds the old app.
        } else {
            let aside = staged.deletingLastPathComponent().appendingPathComponent("old-" + installed.lastPathComponent)
            try? fm.removeItem(at: aside)
            do {
                try fm.moveItem(at: installed, to: aside)
            } catch {
                throw UpdateError.cantReplace("macOS didn't let the app replace itself. Allow Auto Applicator in System Settings › Privacy & Security › App Management, or open the new disk image and drag the app over the old one.")
            }
            do {
                try fm.moveItem(at: staged, to: installed)
            } catch {
                try? fm.moveItem(at: aside, to: installed)
                throw UpdateError.cantReplace("Couldn't put the new version in place (\(error.localizedDescription)); the old one is still there.")
            }
            try? fm.moveItem(at: aside, to: staged)
        }
        // The old app: deleted, or left in the temporary folder (macOS empties it) if deleting isn't allowed.
        try? fm.removeItem(at: staged)
        rmdir(staged.deletingLastPathComponent().path)  // the staging folder, once empty
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.path)
        _ = LSRegisterURL(installed as CFURL, true)
        Log.info("Installed version \(infoPlist(installed)?["CFBundleShortVersionString"] as? String ?? "?") at \(installed.path)")
    }

    /// Opens `app` once the process `pid` (this app) has quit. A copy using a test data folder (AA_HOME) opens with
    /// the same one, never the real one.
    public static func relaunch(_ app: URL, after pid: Int32) {
        let env = ProcessInfo.processInfo.environment
        var open: [String] = []
        for key in ["AA_HOME", "AA_UPDATE_FEED"] { if let v = env[key], !v.isEmpty { open += ["--env", "\(key)=\(v)"] } }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "pid=$1; shift; while kill -0 \"$pid\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$@\"",
                       "sh", String(pid)] + open + [app.path]
        try? p.run()
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError.download("\((tool as NSString).lastPathComponent) failed: \(text.prefix(300))")
        }
        return text
    }
}

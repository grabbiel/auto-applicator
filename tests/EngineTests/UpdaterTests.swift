import Foundation
import XCTest
@testable import Engine

/// In-app updates: only a newer version that runs here is offered, only the exact disk image is accepted, only the same
/// app at the promised version with an intact signature is installed, and the old app stays whole until it is swapped.
final class UpdaterTests: XCTestCase {
    private let fm = FileManager.default
    private var dir: URL!
    private let appID = "io.github.grabbiel.autoapplicator.updater-test"  // never the real app's, which macOS routes links to

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("Applications").path)
        try? fm.removeItem(at: dir)
    }

    func testVersionsCompareByNumberNotText() {
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(Updater.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(Updater.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(Updater.isNewer("1.1.0", than: "1.2.0"))
    }

    func testOnlyANewerVersionThatRunsHereIsOffered() async throws {
        let feed = dir.appendingPathComponent("update.json")
        func offer(_ json: String, current: String = "1.1.0") async throws -> UpdateInfo? {
            try Data(json.utf8).write(to: feed)
            return try await Updater.check(current: current, feed: feed, system: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1))
        }
        let sha = String(repeating: "a", count: 64)
        let url = "https://github.com/grabbiel/auto-applicator/releases/download/v1.2.0/AutoApplicator.dmg"
        let info = try await offer(#"{"version":"1.2.0","url":"\#(url)","sha256":"\#(sha)","size":10,"minimumSystemVersion":"14.0","notes":["Faster"]}"#)
        XCTAssertEqual(info?.version, "1.2.0")
        XCTAssertEqual(info?.notes, ["Faster"])
        let same = try await offer(#"{"version":"1.2.0","url":"\#(url)","sha256":"\#(sha)","size":10}"#, current: "1.2.0")
        XCTAssertNil(same, "the version it has")
        let older = try await offer(#"{"version":"1.0.1","url":"\#(url)","sha256":"\#(sha)","size":10}"#)
        XCTAssertNil(older, "never a downgrade")
        let tooNew = try await offer(#"{"version":"1.2.0","url":"\#(url)","sha256":"\#(sha)","size":10,"minimumSystemVersion":"28.0"}"#)
        XCTAssertNil(tooNew, "needs a newer macOS")
        do {
            _ = try await offer(#"{"version":"1.2.0","url":"\#(url)","sha256":"abc","size":10}"#)
            XCTFail("a release without a proper checksum")
        } catch {}
        try fm.removeItem(at: feed)
        let none = try await Updater.check(current: "1.1.0", feed: feed)
        XCTAssertNil(none, "a release without update.json offers nothing")
    }

    func testDiskImagesComeOnlyFromThisAppsReleases() {
        let release = URL(string: "https://github.com/grabbiel/auto-applicator/releases/download/v1.2.0/AutoApplicator.dmg")!
        XCTAssertTrue(Updater.accepts(release, from: Updater.defaultFeed))
        XCTAssertFalse(Updater.accepts(URL(string: "https://example.com/AutoApplicator.dmg")!, from: Updater.defaultFeed))
        XCTAssertFalse(Updater.accepts(URL(string: "https://github.com/someone-else/auto-applicator/releases/download/v9/AutoApplicator.dmg")!, from: Updater.defaultFeed))
        XCTAssertFalse(Updater.accepts(URL(fileURLWithPath: "/tmp/AutoApplicator.dmg"), from: Updater.defaultFeed))
        XCTAssertTrue(Updater.accepts(URL(fileURLWithPath: "/tmp/AutoApplicator.dmg"), from: URL(fileURLWithPath: "/tmp/update.json")),
                      "a test feed (AA_UPDATE_FEED) may name a local disk image")
    }

    func testOnlyTheExactDiskImageIsKept() async throws {
        let image = dir.appendingPathComponent("source.dmg")
        try Data("not really a disk image".utf8).write(to: image)
        let right = UpdateInfo(version: "1.2.0", url: image, sha256: try sha256(image), size: 23)
        let got = try await Updater.download(right, into: dir.appendingPathComponent("downloads"))
        XCTAssertEqual(got.lastPathComponent, "AutoApplicator-1.2.0.dmg")

        for wrong in [UpdateInfo(version: "1.2.0", url: image, sha256: String(repeating: "0", count: 64), size: 23),
                      UpdateInfo(version: "1.2.0", url: image, sha256: right.sha256, size: 24)] {
            do {
                _ = try await Updater.download(wrong, into: dir.appendingPathComponent("downloads"))
                XCTFail("a different file was kept")
            } catch let error as UpdateError {
                guard case .damaged = error else { return XCTFail("\(error)") }
            }
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("downloads/AutoApplicator-1.2.0.dmg").path))
        }
    }

    func testANewVersionReplacesTheAppInOneStep() throws {
        let installed = try makeApp(in: dir.appendingPathComponent("Applications"), version: "1.1.0")
        let (dmg, info) = try makeRelease(version: "1.2.0")

        let staged = try Updater.stage(dmg: dmg, info: info, installed: installed)
        XCTAssertEqual(version(of: installed), "1.1.0", "staging leaves the installed app alone")
        XCTAssertEqual(version(of: staged), "1.2.0")
        XCTAssertNil(Updater.cantReplace(installed))

        try Updater.install(staged: staged, over: installed)
        XCTAssertEqual(version(of: installed), "1.2.0")
        XCTAssertFalse(fm.fileExists(atPath: staged.path), "the old app is gone")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["Auto Applicator.app"])
        XCTAssertNoThrow(try Updater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", installed.path]))
    }

    func testOnlyTheSameAppAtThePromisedVersionWithAnIntactSignatureIsStaged() throws {
        let installed = try makeApp(in: dir.appendingPathComponent("Applications"), version: "1.1.0")
        func refused(_ dmg: URL, _ info: UpdateInfo, _ why: String, saying: String) {
            XCTAssertThrowsError(try Updater.stage(dmg: dmg, info: info, installed: installed), why) { error in
                guard case .damaged(let said)? = error as? UpdateError else { return XCTFail("\(why): \(error)") }
                XCTAssertTrue(said.contains(saying), "\(why): \(said)")
            }
        }
        var (dmg, info) = try makeRelease(version: "1.2.0")
        info.version = "1.3.0"
        refused(dmg, info, "not the promised version", saying: "not version 1.3.0")

        (dmg, info) = try makeRelease(version: "1.2.0", id: "com.example.other")
        refused(dmg, info, "another app", saying: "another app")

        (dmg, info) = try makeRelease(version: "1.2.0") { app in
            // Changed after signing: the signature no longer covers it.
            try Data("#!/bin/sh\necho changed\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/extra.sh"))
        }
        refused(dmg, info, "a broken signature", saying: "signature")
        XCTAssertEqual(version(of: installed), "1.1.0")
    }

    func testAnAppThatCantReplaceItselfSaysSo() throws {
        let apps = dir.appendingPathComponent("Applications")
        let installed = try makeApp(in: apps, version: "1.1.0")
        let (dmg, info) = try makeRelease(version: "1.2.0")
        let staged = try Updater.stage(dmg: dmg, info: info, installed: installed)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: apps.path)
        XCTAssertNotNil(Updater.cantReplace(installed))
        XCTAssertThrowsError(try Updater.install(staged: staged, over: installed)) { error in
            guard case .cantReplace? = error as? UpdateError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(version(of: installed), "1.1.0")
        XCTAssertNotNil(Updater.cantReplace(URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABC/d/Auto Applicator.app")))
    }

    // MARK: - helpers

    /// An ad-hoc signed "Auto Applicator.app" (its program is a copy of /usr/bin/true).
    private func makeApp(in folder: URL, version: String, id: String? = nil, afterSigning: ((URL) throws -> Void)? = nil) throws -> URL {
        let app = folder.appendingPathComponent("Auto Applicator.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/AutoApplicator"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": id ?? appID, "CFBundleShortVersionString": version, "CFBundleVersion": "1",
            "CFBundleExecutable": "AutoApplicator", "CFBundlePackageType": "APPL", "CFBundleName": "Auto Applicator",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("icon".utf8).write(to: app.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        try Updater.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try afterSigning?(app)
        return app
    }

    /// A disk image like a release's (the app and an Applications shortcut) and its update.json details.
    private func makeRelease(version: String, id: String? = nil, afterSigning: ((URL) throws -> Void)? = nil) throws -> (URL, UpdateInfo) {
        let source = dir.appendingPathComponent("release-\(UUID().uuidString)", isDirectory: true)
        _ = try makeApp(in: source, version: version, id: id, afterSigning: afterSigning)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let dmg = dir.appendingPathComponent("AutoApplicator-\(UUID().uuidString).dmg")
        try Updater.run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-format", "UDZO", "-volname", "Auto Applicator",
                                             "-srcfolder", source.path, dmg.path])
        let size = try XCTUnwrap((try fm.attributesOfItem(atPath: dmg.path))[.size] as? Int)
        return (dmg, UpdateInfo(version: version, url: dmg, sha256: try sha256(dmg), size: size))
    }

    private func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    private func sha256(_ url: URL) throws -> String {
        try Updater.run("/usr/bin/shasum", ["-a", "256", url.path]).split(separator: " ").first.map(String.init) ?? ""
    }
}

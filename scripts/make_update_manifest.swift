// Writes dist/update.json: what the app's updater reads from the newest release (Sources/Engine/System/Updater.swift).
//   swift scripts/make_update_manifest.swift <dist folder> <owner/repo> [release notes .md]
// The dist folder holds AutoApplicator.dmg and the app's Info.plist (both from scripts/package.sh). "What's new" is
// the list of merged pull requests in the release notes, without bots.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_update_manifest: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: make_update_manifest.swift <dist folder> <owner/repo> [release notes .md]") }
let dist = URL(fileURLWithPath: args[1], isDirectory: true)
let repo = args[2]
let dmg = dist.appendingPathComponent("AutoApplicator.dmg")

guard let plistData = try? Data(contentsOf: dist.appendingPathComponent("Info.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
      let version = plist["CFBundleShortVersionString"] as? String
else { fail("no Info.plist in \(dist.path) (run scripts/package.sh)") }
guard let image = try? Data(contentsOf: dmg) else { fail("no AutoApplicator.dmg in \(dist.path)") }

var notes: [String] = []
if args.count >= 4, let text = try? String(contentsOfFile: args[3], encoding: .utf8) {
    // "* Title by @someone in https://github.com/…/pull/7"
    for line in text.split(separator: "\n") where line.hasPrefix("* ") && line.contains(" in https://") {
        guard !line.contains("[bot]") else { continue }
        var title = String(line.dropFirst(2))
        if let by = title.range(of: " by @", options: .backwards) { title = String(title[..<by.lowerBound]) }
        notes.append(title.trimmingCharacters(in: .whitespaces))
    }
}

var manifest: [String: Any] = [
    "version": version,
    "url": "https://github.com/\(repo)/releases/download/v\(version)/AutoApplicator.dmg",
    "sha256": SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined(),
    "size": image.count,
    "page": "https://github.com/\(repo)/releases/tag/v\(version)",
]
if let build = (plist["CFBundleVersion"] as? String).flatMap(Int.init) { manifest["build"] = build }
if let minimum = plist["LSMinimumSystemVersion"] as? String { manifest["minimumSystemVersion"] = minimum }
if !notes.isEmpty { manifest["notes"] = notes }

let out = dist.appendingPathComponent("update.json")
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: out)
print("Wrote \(out.path) (version \(version), \(notes.count) notes)")

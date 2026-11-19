import AdminKit
import AppKit
import SwiftUI

/// What the cloud browser runs on in the AWS account, and what it costs.
struct CloudView: View {
    @Environment(AdminModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = model.snapshot {
                if let stack = snapshot.stack {
                    stackCard(stack, snapshot)
                    signInCard(stack)
                    browsersCard(snapshot)
                    aiCard(stack, snapshot)
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            CardTitle(title: "Not set up", detail: "No stack called \(model.settings.stack) in account \(snapshot.account), \(model.settings.region).")
                            Button("Set it up…") { model.updateCloud() }.buttonStyle(PrimaryButtonStyle()).disabled(model.working)
                        }
                    }
                }
                costCard
                releaseCard
            } else {
                Card { Text(model.loading ? "Reading your AWS account…" : "Nothing read from AWS yet.").font(Typo.body).foregroundStyle(Palette.textSoft) }
            }
        }
    }

    private func stackCard(_ stack: CloudStack, _ snapshot: CloudSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    CardTitle(title: "The stack", detail: "Sign-in, the roles that limit each person to their own browser, and the cloud AI: infra/cloud-browser.yaml, deployed with CloudFormation.")
                    Spacer()
                    if stack.busy { Pill(text: "Updating", tone: .blue) }
                    else if !stack.healthy { Pill(text: "Needs a look", tone: .red) }
                    else if snapshot.templateChanged == true || !stack.perPerson { Pill(text: "Update waiting", tone: .amber) }
                    else { Pill(text: "Up to date", tone: .green, symbol: "checkmark") }
                }
                Fact(label: "Name", value: stack.name, code: true)
                Fact(label: "Status", value: stack.status.replacingOccurrences(of: "_", with: " ").lowercased())
                if let updated = stack.updated { Fact(label: "Last deployed", value: "\(updated.formatted(date: .abbreviated, time: .shortened)) (\(updated.ago))") }
                Fact(label: "Account", value: "\(snapshot.account) · \(stack.region ?? model.settings.region)", code: true)
                if !stack.perPerson {
                    note("Everyone still shares one browser in this cloud. Updating gives each person their own.", .amber)
                } else if snapshot.templateChanged == true {
                    note("The template in the project folder differs from what's deployed.", .amber)
                }
                HStack(spacing: 8) {
                    Button("Update the cloud…") { model.updateCloud() }
                        .buttonStyle(snapshot.templateChanged == true || !stack.perPerson ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                        .disabled(model.working || stack.busy)
                    Button("Open in CloudFormation") { model.openConsole("cloudformation/home?region=\(model.settings.region)#/stacks?filteringText=\(stack.name)") }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("All its resources") { model.openConsole("resource-groups/group/auto-applicator") }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 2)
            }
        }
    }

    private func signInCard(_ stack: CloudStack) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Sign-in", detail: "Invite-only (Amazon Cognito). Nobody can sign up; Google or Apple only work for an invited address.")
                if let host = stack.signInHost { Fact(label: "Sign-in page", value: host, code: true) }
                Fact(label: "Ways to sign in", value: (["Password", "Passkey"] + stack.providers).joined(separator: ", "))
                if let pool = stack.userPoolId { Fact(label: "User pool", value: pool, code: true) }
                if let refusals = model.snapshot?.refusals {
                    Fact(label: "Turned away", value: refusals == 0 ? "Nobody in the last 7 days"
                         : "\(refusals) Google or Apple sign-in\(refusals == 1 ? "" : "s") without an invitation in the last 7 days")
                }
                Text("Google and Apple are set up in a terminal, because they need a secret typed in: bash scripts/deploy_cloud.sh --sign-in-setup")
                    .font(Typo.small).foregroundStyle(Palette.textSoft).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let pool = stack.userPoolId {
                    Button("Open in Cognito") { model.openConsole("cognito/v2/idp/user-pools/\(pool)/users?region=\(model.settings.region)") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func browsersCard(_ snapshot: CloudSnapshot) -> some View {
        let unused = snapshot.places.unused(by: snapshot.people)
        let running = snapshot.people.reduce(0) { $0 + $1.running.count }
        let without = snapshot.people.filter { !$0.hasOwnBrowser && $0.state != .revoked }.count
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Browsers", detail: "Each person's own Chrome (Amazon Bedrock AgentCore Browser) and the cookies it keeps. A browser costs nothing until a session runs; nothing is recorded.")
                Fact(label: "Browsers", value: "\(snapshot.places.browsers.count), with \(snapshot.places.profiles.count) cookie profile\(snapshot.places.profiles.count == 1 ? "" : "s")")
                Fact(label: "Running now", value: running == 0 ? "None" : "\(running) session\(running == 1 ? "" : "s")")
                if without > 0 { note("\(without) \(without == 1 ? "person has" : "people have") no browser of their own (People › Give them one).", .amber) }
                if !unused.isEmpty {
                    note(unused.count == 1 ? "1 browser or cookie profile belongs to an account that no longer exists."
                         : "\(unused.count) browsers and cookie profiles belong to accounts that no longer exist.", .amber)
                }
                Fact(label: "For the tests", value: snapshot.places.hasTestBrowser ? "aa_tests (no sign-in can use it)" : "Not made")
                HStack(spacing: 8) {
                    if !unused.isEmpty { Button("Delete the unused…") { model.tidy() }.buttonStyle(SecondaryButtonStyle(destructive: true)) }
                    if !snapshot.places.hasTestBrowser {
                        Button("Make a test browser") { Task { await model.makeTestBrowser() } }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Open in AgentCore") { model.openConsole("bedrock-agentcore/builtInTools?region=\(model.settings.region)") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .disabled(model.working)
            }
        }
    }

    private func aiCard(_ stack: CloudStack, _ snapshot: CloudSnapshot) -> some View {
        let allowed = snapshot.people.filter(\.cloudAI)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Cloud AI", detail: "A model on Amazon Bedrock for the form questions the on-device AI can't answer. Off for everyone until you switch it on for them (People › ⋯).")
                Fact(label: "Model", value: stack.helperModel ?? "none", code: true)
                Fact(label: "Function", value: stack.helperFunction ?? "none", code: true)
                Fact(label: "Who may ask", value: allowed.isEmpty ? "Nobody" : allowed.map(\.email).joined(separator: ", "))
                if let questions = snapshot.questions { Fact(label: "Last 7 days", value: "\(questions) question\(questions == 1 ? "" : "s")") }
            }
        }
    }

    private var costCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "This month's bill so far", detail: "For the whole AWS account, by service. AWS charges $0.01 each time this is looked up, so it's only read when you ask.")
                if let cost = model.cost {
                    if cost.services.isEmpty {
                        Text("Under a cent so far.").font(Typo.body).foregroundStyle(Palette.text)
                    } else {
                        ForEach(cost.services, id: \.name) { service in
                            Fact(label: Self.money(service.amount, cost.currency), value: service.name)
                        }
                        Divider().overlay(Palette.line)
                        Fact(label: Self.money(cost.total, cost.currency), value: "Total")
                    }
                }
                Button(model.costLoading ? "Looking it up…" : model.cost == nil ? "Look it up" : "Look it up again") { Task { await model.lookUpCost() } }
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.costLoading)
            }
        }
    }

    private var releaseCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "The app people get", detail: "They download it from the releases page; it updates itself from there. Their copy learns where your cloud is from its cloud.json.")
                Fact(label: "Published", value: model.publishedVersion ?? "unknown")
                Fact(label: "In the project", value: model.projectVersion ?? "unknown")
                if let published = model.publishedVersion, let project = model.projectVersion, published != project {
                    note("Version \(project) isn't published yet: a release goes out when VERSION changes on main.", .amber)
                }
                HStack(spacing: 8) {
                    Button("Releases") { NSWorkspace.shared.open(URL(string: "https://github.com/grabbiel/auto-applicator/releases")!) }.buttonStyle(SecondaryButtonStyle())
                    Button("Show cloud.json") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.settings.repo).appendingPathComponent("Resources/CloudConfig.json")])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Resources/CloudConfig.json: an invited person saves it as ~/Library/Application Support/AutoApplicator/cloud.json")
                }
            }
        }
    }

    private func note(_ text: String, _ tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(tone.color).padding(.top, 1)
            Text(text).font(Typo.small).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func money(_ amount: Double, _ currency: String) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}

/// Lets one button be green or white depending on whether it's the thing to do.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Every command this app ran and what it printed.
struct ActivityView: View {
    @Environment(AdminModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                CardTitle(title: "What ran", detail: "Changes are made by scripts/deploy_cloud.sh, the same as from a terminal. This list is kept until you quit.")
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.log.isEmpty)
            }
            Card(padding: 14) {
                if model.log.isEmpty {
                    Text("Nothing yet.").font(Typo.body).foregroundStyle(Palette.textSoft)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(line.time.formatted(date: .omitted, time: .standard)).font(Typo.code).foregroundStyle(Palette.textFaint)
                                Text((line.kind == .command ? "$ " : "") + line.text)
                                    .font(line.kind == .command ? Typo.code.weight(.bold) : Typo.code)
                                    .foregroundStyle(line.kind == .problem ? Palette.red : line.kind == .command ? Palette.ink : Palette.text)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.top, line.kind == .command ? 6 : 0)
                        }
                    }
                }
            }
        }
    }
}

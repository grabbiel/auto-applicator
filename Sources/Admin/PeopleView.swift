import AdminKit
import AppKit
import SwiftUI

/// Who is invited, what each of them has, and what they've used.
struct PeopleView: View {
    @Environment(AdminModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                // The green box (the main app's search box): an address in, an invitation out.
                HStack(spacing: 10) {
                    Image(systemName: "envelope.fill").font(.system(size: 13)).foregroundStyle(Palette.green)
                    TextField("Invite someone by email", text: $model.inviteEmail)
                        .textFieldStyle(.plain).font(.system(size: 14)).onSubmit { Task { await model.invite() } }
                    Button("Invite") { Task { await model.invite() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.canInvite || model.working || model.snapshot?.stack == nil)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Palette.green, lineWidth: 2))
                Text("Amazon Cognito emails them a temporary password (good for 7 days). They get a cloud browser and a cookie profile of their own, and nothing else in your AWS account: not anyone else's browser, not the cloud AI unless you switch it on for them.")
                    .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
            }

            if let stack = model.snapshot?.stack, !stack.perPerson {
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.amber)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Everyone still shares one browser").font(Typo.bodyStrong).foregroundStyle(Palette.text)
                            Text("This cloud was set up before each person had a browser of their own: whoever you invite would use the same Chrome and cookies as you. Update the cloud before inviting anyone.")
                                .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                            Button("Update the cloud…") { model.updateCloud() }.buttonStyle(PrimaryButtonStyle()).disabled(model.working)
                        }
                    }
                }
            }

            if model.snapshot == nil {
                Card { Text(model.loading ? "Reading your AWS account…" : "Nothing read from AWS yet.").font(Typo.body).foregroundStyle(Palette.textSoft) }
            } else if model.snapshot?.stack == nil {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(title: "The cloud browser isn't set up", detail: "No stack called \(model.settings.stack) in this account and region.")
                        Button("Set it up…") { model.updateCloud() }.buttonStyle(PrimaryButtonStyle()).disabled(model.working)
                    }
                }
            } else if model.people.isEmpty {
                Card { Text("Nobody is invited yet.").font(Typo.body).foregroundStyle(Palette.textSoft) }
            } else {
                VStack(spacing: 10) {
                    ForEach(model.people) { person in PersonRow(person: person) }
                }
            }
        }
    }
}

private struct PersonRow: View {
    @Environment(AdminModel.self) private var model
    var person: Person

    private var isOpen: Bool { model.expanded.contains(person.id) }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(tone.wash)
                        Text(person.email.prefix(1).uppercased()).font(.system(size: 14, weight: .heavy)).foregroundStyle(tone.color)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(person.email).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink).textSelection(.enabled)
                            statePill
                            if !person.running.isEmpty { Pill(text: "Browser running", tone: .green, symbol: "circle.fill") }
                            if person.cloudAI { Pill(text: "Cloud AI", tone: .blue) }
                        }
                        Text(person.signsInWith).font(Typo.small).foregroundStyle(Palette.textSoft)
                        Text(usage).font(Typo.small).foregroundStyle(Palette.textSoft)
                        if !person.hasOwnBrowser {
                            Text("No browser of their own yet.").font(Typo.small).foregroundStyle(Palette.amber)
                        }
                    }
                    Spacer(minLength: 8)
                    actions
                }
                if isOpen { details }
            }
        }
    }

    private var tone: Tone {
        switch person.state {
        case .active: .green
        case .invited: .blue
        case .revoked: .red
        }
    }

    @ViewBuilder private var statePill: some View {
        switch person.state {
        case .active: EmptyView()
        case .invited: Pill(text: "Invited", tone: .blue)
        case .revoked: Pill(text: "Revoked", tone: .red, symbol: "lock.fill")
        }
    }

    private var usage: String {
        guard let last = person.lastUsed else { return "Hasn't used the cloud browser." }
        let week = person.usage()
        let hours = week.hours < 0.1 ? "a few minutes" : String(format: "%.1f h", week.hours)
        // Only the newest hundred sessions are read: when they're all this week's, there may be more.
        let atLeast = week.sessions >= 100 && week.sessions == person.sessions.count ? "at least " : ""
        let recent = week.sessions == 0 ? "nothing in the last 7 days"
            : "\(atLeast)\(week.sessions) session\(week.sessions == 1 ? "" : "s"), \(hours) in the last 7 days"
        return (person.running.isEmpty ? "Last used \(last.ago)" : "Started \(last.ago)") + " · " + recent
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if !person.hasOwnBrowser, person.state != .revoked {
                Button("Give them one") { Task { await model.repair(person) } }.buttonStyle(SecondaryButtonStyle())
            }
            switch person.state {
            case .invited: Button("Send again") { Task { await model.sendAgain(person) } }.buttonStyle(SecondaryButtonStyle())
            case .revoked: Button("Let back in") { Task { await model.letBackIn(person) } }.buttonStyle(SecondaryButtonStyle())
            case .active: EmptyView()
            }
            if !person.running.isEmpty {
                Button("End session") { Task { await model.stop(person) } }.buttonStyle(SecondaryButtonStyle())
            }
            Menu {
                Button(person.cloudAI ? "Take the cloud AI away" : "Let them ask the cloud AI") {
                    Task { await model.setCloudAI(person, on: !person.cloudAI) }
                }
                Button(isOpen ? "Hide details" : "Show details") {
                    if isOpen { model.expanded.remove(person.id) } else { model.expanded.insert(person.id) }
                }
                Button("Copy the address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(person.email, forType: .string)
                }
                Divider()
                if person.state != .revoked { Button("Revoke…") { model.revoke(person) } }
                Button("Remove…", role: .destructive) { model.remove(person) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 18, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.lineStrong))
        }
        .disabled(model.working)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Palette.line)
            Fact(label: "Account ID", value: person.id, code: true)
            Fact(label: "Browser", value: person.browserId ?? "none", code: true)
            Fact(label: "Cookie profile", value: person.profileId ?? "none", code: true)
            if let created = person.created { Fact(label: "Invited", value: created.formatted(date: .abbreviated, time: .shortened)) }
            Fact(label: "May use", value: person.state == .revoked ? "Nothing while revoked."
                 : "Their own browser and cookies" + (person.cloudAI ? ", and the cloud AI." : ". Nothing else in the account."))
            if !person.sessions.isEmpty {
                Text("Recent sessions").font(Typo.eyebrow).foregroundStyle(Palette.textSoft).padding(.top, 4)
                ForEach(person.sessions.prefix(5)) { session in
                    HStack(spacing: 10) {
                        Circle().fill(session.running ? Palette.green : Palette.lineStrong).frame(width: 6, height: 6)
                        Text(session.started.formatted(date: .abbreviated, time: .shortened)).font(Typo.small).foregroundStyle(Palette.text)
                        Text(session.running ? "running" : Self.length(session.duration())).font(Typo.small).foregroundStyle(Palette.textSoft)
                        Spacer()
                    }
                }
            }
        }
    }

    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(max(1, minutes)) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}

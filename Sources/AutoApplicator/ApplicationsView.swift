import Engine
import SwiftUI

/// Every job it has looked at, newest first, with what happened and the proof of what was sent.
struct ApplicationsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all
    @State private var expanded: String?

    enum Filter: String, CaseIterable { case all = "All", sent = "Sent", practice = "Practice", needsYou = "Needs you", unfinished = "Didn't finish" }

    private var rows: [JobRecord] {
        model.jobs.filter { job in
            let status = job.status
            let keep: Bool = switch filter {
            case .all: status != .skippedBlacklist && status != .skippedTitleFilter
            case .sent: status == .applied
            case .practice: status == .practiceComplete
            case .needsYou: status == .needsAnswer
            case .unfinished: status?.isFailure == true
            }
            guard keep else { return false }
            let q = model.applicationsQuery.trimmed.lowercased()
            return q.isEmpty || job.title.lowercased().contains(q) || job.company.lowercased().contains(q)
        }
    }

    var body: some View {
        Page(title: "Applications", subtitle: "Every job it worked on. Open one to see the notes, the posting, and a PDF of exactly what was filled in.") {
            @Bindable var model = model
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        TabStrip(options: Filter.allCases, selection: $filter, title: \.rawValue, count: { $0 == .all ? nil : count($0) })
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Palette.textFaint).font(.system(size: 11, weight: .bold))
                            TextField("Job or company", text: $model.applicationsQuery).textFieldStyle(.plain).font(Typo.body)
                            if !model.applicationsQuery.isEmpty {
                                Button { model.applicationsQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textFaint) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 210, height: 32)
                        .background(Palette.sunken, in: Capsule())
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    jobList
                }
            }
        }
    }

    @ViewBuilder private var jobList: some View {
        if rows.isEmpty {
            EmptyState(symbol: "tray", title: model.jobs.isEmpty ? "No applications yet" : "Nothing here",
                       message: model.jobs.isEmpty ? "Start a practice run from Today. Each job it works on is listed here."
                                                   : "No jobs match this filter.")
                .hairline(.top)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { job in
                    JobRow(job: job, expanded: expanded == job.id) {
                        withAnimation(.snappy(duration: 0.25)) { expanded = expanded == job.id ? nil : job.id }
                    }
                    .hairline(.top)
                }
            }
        }
    }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .all: model.jobs.count
        case .sent: model.jobs.filter { $0.status == .applied }.count
        case .practice: model.jobs.filter { $0.status == .practiceComplete }.count
        case .needsYou: model.jobs.filter { $0.status == .needsAnswer }.count
        case .unfinished: model.jobs.filter { $0.status?.isFailure == true }.count
        }
    }
}

private struct JobRow: View {
    @Environment(AppModel.self) private var model
    var job: JobRecord
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                Hover { hovering in
                    HStack(spacing: 14) {
                        Monogram(name: job.company.isEmpty ? job.title : job.company, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title.isEmpty ? "Job \(job.id)" : job.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                            Text([job.company, job.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Typo.small).foregroundStyle(Palette.textSoft).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        if let ats = job.ats { Text(ats.label).font(Typo.small).foregroundStyle(Palette.textFaint) }
                        if let status = job.status {
                            Pill(text: status.shortLabel, tone: status.tone, symbol: status.symbol)
                        }
                        Text(job.updatedAt?.relative ?? "").font(Typo.small).foregroundStyle(Palette.textFaint).frame(width: 92, alignment: .trailing)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.textFaint)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(hovering || expanded ? Palette.sunken.opacity(0.6) : .clear)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)

            if expanded { details.transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = job.status {
                Text(status.label).font(Typo.bodyStrong).foregroundStyle(status.tone.color)
            }
            if !job.notes.isEmpty {
                Text(job.notes).font(Typo.body).foregroundStyle(Palette.textSoft).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let url = URL(string: job.url), !job.url.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Job posting", systemImage: "arrow.up.right.square") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let url = URL(string: job.externalURL), !job.externalURL.isEmpty {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Company page", systemImage: "building.2") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !job.evidence.isEmpty, FileManager.default.fileExists(atPath: job.evidence) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: job.evidence)) } label: { Label("What was filled in (PDF)", systemImage: "doc.richtext") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if job.status == .needsAnswer {
                    Button("Answer its questions") { model.page = .inbox }.buttonStyle(PrimaryButtonStyle())
                }
                Spacer()
                Button("Remove") { model.removeJob(job) }
                    .buttonStyle(QuietButtonStyle(color: Palette.red))
                    .help("Forget this job. If it shows up in a search again, it will be tried again.")
            }
        }
        .padding(.leading, 68)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .padding(.top, 2)
        .background(Palette.sunken.opacity(0.6))
    }
}

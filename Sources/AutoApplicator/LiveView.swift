import Engine
import SwiftUI

/// What the run is doing right now: the page it's on (a live picture), the current job's steps, and the results.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRunning || !model.outcomes.isEmpty || model.runError != nil || model.lastSummary != nil {
            running
        } else {
            Page(title: "Live", subtitle: "Watch each application as it's filled in.") {
                Card {
                    EmptyState(symbol: "dot.radiowaves.left.and.right", title: "Nothing running right now",
                               message: "Start a run from Today. You'll see the page it's working on and every step it takes, here.",
                               actionTitle: "Go to Today") { model.page = .home }
                }
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 18) {
                browserFrame
                VStack(spacing: 14) {
                    nowCard
                    resultsCard
                }
                .frame(width: 330)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .background(Palette.canvas)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(model.isRunning ? "Live" : "Run finished").font(Typo.display(24)).foregroundStyle(Palette.ink)
                    Pill(text: model.isRunning ? "LIVE" : "Done", tone: model.isRunning ? .red : .neutral, solid: model.isRunning)
                    Pill(text: model.runPractice ? "Practice" : "Sending for real", tone: model.runPractice ? .blue : .green)
                    if model.runInCloud { Pill(text: "Cloud browser", tone: .neutral, symbol: "cloud.fill") }
                }
                Text(model.isRunning ? model.runPhase : (model.lastSummary?.headline ?? model.runError ?? ""))
                    .font(Typo.body).foregroundStyle(Palette.textSoft).lineLimit(2)
            }
            Spacer()
            if model.isRunning {
                if let started = model.runStartedAt {
                    Text(started, style: .timer).font(Typo.number(14, .medium)).foregroundStyle(Palette.textSoft).padding(.trailing, 6)
                }
                Button { model.stopRun() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("See applications") { model.page = .applications }.buttonStyle(SecondaryButtonStyle())
                if !model.pending.isEmpty {
                    Button("Answer \(model.pending.count) question\(model.pending.count == 1 ? "" : "s")") { model.page = .inbox }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    // A window-like frame around the live picture of the automated browser.
    private var browserFrame: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { c in
                    Circle().fill(c.opacity(0.85)).frame(width: 10, height: 10)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(model.liveURL.isEmpty ? "about:blank" : model.liveURL).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Palette.textSoft)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .frame(maxWidth: 360)
                .background(Palette.sunken, in: Capsule())
                Spacer()
                if model.isRunning { PulsingDot(color: Palette.green) } else { Color.clear.frame(width: 14) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Palette.surface)
            .hairline()

            ZStack {
                Palette.sunken
                if let image = model.livePreview {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.isRunning ? (model.runInCloud ? "Starting Chrome in the cloud…" : "Opening LinkedIn…") : "The browser closed when the run finished.")
                            .font(Typo.small).foregroundStyle(Palette.textFaint)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.livePreview == nil ? .center : .top)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.edge))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    private var nowCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Now").font(Typo.heading(15)).foregroundStyle(Palette.ink)
                if let job = model.currentJob {
                    HStack(spacing: 10) {
                        Monogram(name: job.company, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(Typo.bodyStrong).lineLimit(2)
                            Text([job.company, job.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Typo.small).foregroundStyle(Palette.textSoft).lineLimit(1)
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(model.currentSteps.suffix(7).enumerated()), id: \.offset) { i, step in
                            let last = i == min(model.currentSteps.count, 7) - 1
                            HStack(alignment: .top, spacing: 8) {
                                if last && model.isRunning {
                                    ProgressView().controlSize(.mini).frame(width: 14)
                                } else {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.greenDeep).frame(width: 14)
                                }
                                Text(step).font(Typo.small).foregroundStyle(last ? Palette.text : Palette.textSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                } else {
                    Text(model.isRunning ? model.runPhase : "Done.").font(Typo.small).foregroundStyle(Palette.textSoft)
                }
                ForEach(model.warnings, id: \.self) { w in
                    Label(w, systemImage: "info.circle").font(Typo.small).foregroundStyle(Palette.amber)
                }
                if let error = model.runError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(Typo.small).foregroundStyle(Palette.red)
                    if model.linkedInState == .signedOut {
                        Button("Sign in to LinkedIn") { model.showSignIn = true }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
        }
    }

    private var resultsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("This run").font(Typo.heading(15)).foregroundStyle(Palette.ink)
                    Spacer()
                    counter(model.outcomes.filter { $0.result.status == .applied || $0.result.status == .practiceComplete }.count, .green, "checkmark")
                    counter(model.outcomes.filter { $0.result.status == .needsAnswer }.count, .amber, "questionmark")
                    counter(model.outcomes.filter { $0.result.status.isFailure }.count, .red, "xmark")
                }
                if model.outcomes.isEmpty {
                    Text("Finished applications will be listed here.").font(Typo.small).foregroundStyle(Palette.textFaint)
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.outcomes) { o in
                                HStack(alignment: .top, spacing: 10) {
                                    Monogram(name: o.card.company, size: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(o.card.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        Text(o.card.company).font(.system(size: 11)).foregroundStyle(Palette.textSoft).lineLimit(1)
                                        if !o.result.notes.isEmpty && o.result.status != .applied && o.result.status != .practiceComplete {
                                            Text(o.result.notes).font(.system(size: 11)).foregroundStyle(Palette.textFaint).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Pill(text: o.result.status.shortLabel, tone: o.result.status.tone)
                                }
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private func counter(_ n: Int, _ tone: Tone, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            Text("\(n)").font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(tone.wash, in: Capsule())
    }
}

import Engine
import SwiftUI

/// A short coach-mark tour after setup: it dims the window, rings one control at a time, and says what it does.
struct TourStop {
    var anchor: String
    var title: String
    var text: String
    var page: AppPage?
}

enum Tour {
    static let stops: [TourStop] = [
        TourStop(anchor: "home.start", title: "Start here",
                 text: "Press this to search LinkedIn and fill applications. In practice mode it fills everything but never presses Submit, so you can check its work first.",
                 page: .home),
        TourStop(anchor: "nav.live", title: "Watch it work",
                 text: "While it runs, see the page it's on and each step it takes. You can stop it at any time."),
        TourStop(anchor: "nav.inbox", title: "Answer what it can't",
                 text: "If a form asks something it doesn't know, the question waits here. Answer it once and it's reused on every future application."),
        TourStop(anchor: "nav.knowledge", title: "It learns as you go",
                 text: "Everything you add makes it smarter. This shows what it knows and the next most useful thing to tell it."),
        TourStop(anchor: "nav.settings", title: "Put it on a schedule",
                 text: "Turn on a daily run in Settings. The app opens by itself, applies, and quits. Nothing to keep open."),
    ]
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }

    func tourOverlay() -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { proxy in TourOverlay(anchors: anchors, proxy: proxy) }
        }
    }
}

private struct TourOverlay: View {
    @Environment(AppModel.self) private var model
    var anchors: [String: Anchor<CGRect>]
    var proxy: GeometryProxy

    var body: some View {
        if let index = model.tourStep, index < Tour.stops.count {
            let stop = Tour.stops[index]
            if let anchor = anchors[stop.anchor] {
                let target = proxy[anchor].insetBy(dx: -6, dy: -6)
                ZStack(alignment: .topLeading) {
                    Cutout(hole: target)
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.green, lineWidth: 2)
                        .frame(width: target.width, height: target.height)
                        .offset(x: target.minX, y: target.minY)
                        .shadow(color: Palette.green.opacity(0.6), radius: 10)
                        .allowsHitTesting(false)
                    bubble(stop, index: index)
                        .frame(width: 300)
                        .offset(bubbleOffset(target, in: proxy.size))
                }
                .transition(.opacity)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: index)
            } else {
                Color.clear.onAppear { if let page = stop.page { model.page = page } }
            }
        }
    }

    private func bubbleOffset(_ target: CGRect, in size: CGSize) -> CGSize {
        let width: CGFloat = 300, height: CGFloat = 190
        // The page shortcuts sit in a row along the top: their tips go underneath.
        if target.maxX + 16 + width < size.width && target.width < size.width / 3 && target.minY > 200 {
            // to the right of the target, vertically centered on it
            let y = min(max(16, target.midY - height / 2), size.height - height - 16)
            return CGSize(width: target.maxX + 16, height: y)
        }
        let x = min(max(16, target.midX - width / 2), size.width - width - 16)
        let below = target.maxY + 14
        return CGSize(width: x, height: below + height < size.height ? below : max(16, target.minY - height - 14))
    }

    private func bubble(_ stop: TourStop, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Tip \(index + 1) of \(Tour.stops.count)", color: Palette.green)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<Tour.stops.count, id: \.self) { i in
                        Capsule().fill(i == index ? Palette.green : Palette.lineStrong).frame(width: i == index ? 14 : 5, height: 5)
                    }
                }
            }
            Text(stop.title).font(Typo.heading(18)).foregroundStyle(Palette.ink)
            Text(stop.text).font(Typo.body).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip tour") { finish() }.buttonStyle(QuietButtonStyle(color: Palette.textSoft))
                Spacer()
                Button(index == Tour.stops.count - 1 ? "Done" : "Next") {
                    if index == Tour.stops.count - 1 { finish() } else {
                        let next = Tour.stops[index + 1]
                        if let page = next.page { model.page = page }
                        model.tourStep = index + 1
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.edge))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private func finish() {
        withAnimation { model.tourStep = nil }
        model.settings.tourComplete = true
    }
}

private struct Cutout: Shape {
    var hole: CGRect
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12), style: .continuous)
        return p
    }
}

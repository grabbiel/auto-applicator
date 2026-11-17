import AppKit
import Engine
import SwiftUI

/// LinkedIn's sign-in page inside the cloud browser, shown live: the person clicks and types in it as in any browser.
/// Signing in there (rather than copying this Mac's sign-in) matters: LinkedIn ends a sign-in that shows up somewhere
/// far away minutes after it was made. Closes by itself once LinkedIn shows the signed-in site, keeping the cookies in
/// the cloud browser's profile for runs.
struct CloudSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var pageSize = WebAgent.viewport
    @State private var status = "Starting Chrome in the cloud…"
    @State private var problem: String?
    @State private var host = "www.linkedin.com"
    @State private var session: (cloud: CloudBrowser, web: WebAgent)?
    @State private var input = RemoteInput.Queue()
    @State private var finished = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0x0A66C2))
                    Text("in").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign in to LinkedIn").font(Typo.heading(20))
                    Text("This is LinkedIn in your cloud browser. Click and type in it as usual: your email, your password, and any code LinkedIn sends you. Use your email and password; LinkedIn's Google and Apple buttons don't work here.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(Palette.surface)
            .hairline()

            ZStack {
                RemoteScreen(image: image, pageSize: pageSize) { input.send($0) }
                if image == nil {
                    VStack(spacing: 12) {
                        if problem == nil { ProgressView().controlSize(.small) }
                        Text(problem ?? status).font(Typo.small).foregroundStyle(problem == nil ? Palette.textSoft : Palette.red)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                }
            }
            .frame(width: Self.screenSize.width, height: Self.screenSize.height)
            .background(Palette.canvas)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text(host).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("Your typing goes straight to LinkedIn's page. It closes by itself once you're signed in.").font(.system(size: 11.5))
            }
            .foregroundStyle(Palette.textSoft)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Palette.surface)
            .hairline(.top)
        }
        .frame(width: Self.screenSize.width)
        .background(Palette.canvas)
        .fittedSheet()
        .task { await run() }
        .onDisappear {
            guard !finished, let session else { return }
            finished = true
            Task {
                await model.finishCloudLinkedInSignIn(session.cloud, signedIn: false)
                session.web.close()
            }
        }
    }

    /// The cloud browser's page at the sheet's width (its shape, within what the screen allows).
    static var screenSize: CGSize {
        let room = SignInSheet.pageSize
        let ratio = WebAgent.viewport.height / WebAgent.viewport.width
        return CGSize(width: room.width, height: min(room.width * ratio, max(room.height, 300)))
    }

    private func run() async {
        do {
            let cloud = try await model.startCloudLinkedInSignIn()
            let web = WebAgent(cloud: cloud)
            session = (cloud, web)
            input.cloud = cloud
            if finished {  // closed while Chrome was starting
                await model.finishCloudLinkedInSignIn(cloud, signedIn: false)
                web.close()
                return
            }
            try await cloud.startScreencast { frame, size in
                image = frame
                pageSize = size
            }
            status = "Opening LinkedIn…"
            try? await web.load(LinkedIn.login, timeout: 30)
            while !Task.isCancelled && !finished {
                host = web.url?.host ?? host
                if let url = web.url, url.host?.hasSuffix("linkedin.com") == true,
                   !["/login", "/checkpoint", "/uas", "/authwall", "/signup"].contains(where: { url.path.hasPrefix($0) }),
                   await web.cookies(for: "linkedin.com").contains(where: { $0.name == "li_at" }) {
                    finished = true
                    await model.finishCloudLinkedInSignIn(cloud, signedIn: true)
                    web.close()
                    dismiss()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        } catch {
            problem = "The cloud browser didn't start: \(error.localizedDescription)"
        }
    }
}

/// What the person does on the cloud browser's picture, in the page's own coordinates.
enum RemoteInput {
    case mouse(CloudBrowser.MouseAction, CGPoint, clicks: Int, pressed: Bool)
    case scroll(CGPoint, dx: Double, dy: Double)
    case text(String)
    case key(CloudBrowser.EditKey)

    /// Delivers input in order, one event at a time, merging bursts of scrolling and mouse moves.
    @MainActor
    final class Queue {
        weak var cloud: CloudBrowser?
        private var pending: [RemoteInput] = []
        private var pumping = false

        func send(_ input: RemoteInput) {
            pending.append(input)
            guard !pumping else { return }
            pumping = true
            Task { await pump() }
        }

        private func pump() async {
            defer { pumping = false }
            while !pending.isEmpty {
                var next = pending.removeFirst()
                switch next {
                case .scroll(let p, var dx, var dy):
                    while case .scroll(_, let x, let y)? = pending.first { dx += x; dy += y; pending.removeFirst() }
                    next = .scroll(p, dx: dx, dy: dy)
                case .mouse(.move, _, _, let pressed):
                    while case .mouse(.move, let p, let c, pressed)? = pending.first { next = .mouse(.move, p, clicks: c, pressed: pressed); pending.removeFirst() }
                default:
                    break
                }
                guard let cloud else { pending.removeAll(); return }
                switch next {
                case .mouse(let action, let p, let clicks, let pressed): await cloud.mouse(action, at: p, clickCount: clicks, pressed: pressed)
                case .scroll(let p, let dx, let dy): await cloud.scroll(at: p, dx: dx, dy: dy)
                case .text(let text): await cloud.typeText(text)
                case .key(let key): await cloud.press(key)
                }
            }
        }
    }
}

/// The live picture, taking clicks, scrolling and typing.
struct RemoteScreen: NSViewRepresentable {
    let image: NSImage?
    let pageSize: CGSize
    let send: (RemoteInput) -> Void

    func makeNSView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView()
        view.send = send
        return view
    }

    func updateNSView(_ view: RemoteScreenView, context: Context) {
        view.image = image
        view.pageSize = pageSize
        view.send = send
    }
}

final class RemoteScreenView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var pageSize = WebAgent.viewport
    var send: (RemoteInput) -> Void = { _ in }
    private var lastPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    }

    /// Where the page is drawn: as large as fits, keeping its shape.
    private var pageRect: CGRect {
        guard pageSize.width > 0, pageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: pageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = pageRect
        guard image != nil, r.contains(p) else { return nil }
        let point = CGPoint(x: (p.x - r.minX) / r.width * pageSize.width, y: (p.y - r.minY) / r.height * pageSize.height)
        lastPoint = point
        return point
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = pagePoint(event) else { return }
        send(.mouse(.move, p, clicks: 0, pressed: false))
        send(.mouse(.down, p, clicks: event.clickCount, pressed: true))
    }

    override func mouseDragged(with event: NSEvent) {
        if let p = pagePoint(event) { send(.mouse(.move, p, clicks: 0, pressed: true)) }
    }

    override func mouseUp(with event: NSEvent) {
        if let p = pagePoint(event) ?? lastPoint { send(.mouse(.up, p, clicks: event.clickCount, pressed: false)) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = pagePoint(event) else { return }
        let step = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
        send(.scroll(p, dx: -event.scrollingDeltaX * step, dy: -event.scrollingDeltaY * step))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { super.keyDown(with: event); return }
        switch Int(event.keyCode) {
        case 51: send(.key(.backspace))
        case 117: send(.key(.delete))
        case 36, 76: send(.key(.enter))
        case 48: send(.key(flags.contains(.shift) ? .backtab : .tab))
        case 123: send(.key(.left))
        case 124: send(.key(.right))
        case 125: send(.key(.down))
        case 126: send(.key(.up))
        case 115: send(.key(.home))
        case 119: send(.key(.end))
        default:
            // Typed characters (not function keys, which AppKit puts in a private-use range, nor control characters).
            guard let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !(0xF700...0xF8FF).contains($0.value) && !CharacterSet.controlCharacters.contains($0) })
            else { return }
            send(.text(text))
        }
    }

    /// Edit › Paste (⌘V), e.g. a password from a password manager.
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { send(.text(text)) }
    }

    override func selectAll(_ sender: Any?) { send(.key(.selectAll)) }
}

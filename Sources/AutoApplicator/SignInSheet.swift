import Engine
import SwiftUI
import WebKit

/// Shows the automation browser inside the app (it normally works hidden).
struct WebViewHost: NSViewRepresentable {
    let agent: WebAgent

    func makeCoordinator() -> WebAgent { agent }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let web = agent.lend()
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: WebAgent) {
        coordinator.reclaim()
    }
}

/// LinkedIn's own sign-in page. The user types their password into LinkedIn; the app only keeps the session cookie
/// (like any browser) and closes the sheet once LinkedIn shows the signed-in feed.
struct SignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = "www.linkedin.com"

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
                    Text("Type your email and password on LinkedIn's page below. If it asks for a code, check your phone or email and type it in here. Auto Applicator never sees or stores your password.")
                        .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(Palette.surface)
            .hairline()

            WebViewHost(agent: model.web)
                .frame(width: 900, height: 560)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text(host).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("It closes by itself once you're signed in.").font(.system(size: 11.5))
            }
            .foregroundStyle(Palette.textSoft)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Palette.surface)
            .hairline(.top)
        }
        .background(Palette.canvas)
        .task { await watch() }
    }

    private func watch() async {
        let web = model.web
        try? await web.load(LinkedIn.login, timeout: 30)
        while !Task.isCancelled {
            host = web.url?.host ?? host
            if let url = web.url, url.host?.hasSuffix("linkedin.com") == true,
               !["/login", "/checkpoint", "/uas", "/authwall"].contains(where: { url.path.hasPrefix($0) }),
               await web.cookies(for: "linkedin.com").contains(where: { $0.name == "li_at" }) {
                model.linkedInState = .signedIn
                model.show("Signed in to LinkedIn.")
                dismiss()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

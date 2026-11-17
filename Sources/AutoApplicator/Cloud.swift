import AppKit
import AuthenticationServices
import Engine
import SwiftUI

/// The optional cloud browser: signing in (invited addresses only: password, passkey, Google or Apple, on the hosted
/// page), testing it, and choosing it for runs.
extension AppModel {
    /// This copy of the app knows where a cloud browser is (scripts/deploy_cloud.sh was run before building it).
    var cloudAvailable: Bool { cloudConfig != nil }
    var cloudSignedIn: Bool { !secrets.cloudRefreshToken.isEmpty }
    /// The next run will use the cloud browser.
    var usesCloud: Bool { cloudAvailable && cloudSignedIn && settings.cloudBrowser }
    /// This copy of the app knows the cloud AI (deployed with it).
    var cloudHelperAvailable: Bool { !(cloudConfig?.helperFunction ?? "").isEmpty }
    /// The next run will ask the cloud AI what the on-device AI can't answer.
    var usesCloudHelper: Bool { usesCloud && cloudHelperAvailable && settings.ai.cloudHelper }

    /// The cloud AI for a run in the cloud browser: asked only about the questions the on-device AI couldn't answer,
    /// with the cloud sign-in's credentials (the only ones allowed to call it).
    func makeCloudHelper() -> AIService? {
        guard let config = cloudConfig, let account = cloudAccount,
              let model = CloudModel(config: config, credentials: { try await account.credentials() }) else { return nil }
        return AIService(model: model)
    }

    /// The account saved (or dropped) its sign-in.
    func cloudSignInChanged(_ token: String?) {
        secrets.cloudRefreshToken = token ?? ""
        if token == nil { secrets.cloudEmail = "" }
    }

    /// `provider` goes straight to Google or Apple instead of the sign-in page.
    func signInToCloud(provider: String? = nil) async {
        guard let account = cloudAccount else { return }
        cloudBusy = "Waiting for you to sign in…"
        defer { cloudBusy = nil }
        let request = account.signInRequest(identityProvider: provider)
        do {
            let callback = try await WebSignIn.shared.open(request.url)
            cloudBusy = "Finishing sign-in…"
            secrets.cloudEmail = try await account.completeSignIn(request, callback: callback)
            settings.cloudBrowser = true
            show("Signed in. Runs now use the cloud browser.")
        } catch is CancellationError {
        } catch CloudError.joined(let joined) where provider == nil {
            // A first Google or Apple sign-in was just joined to the invitation; the same provider lets it through now.
            await signInToCloud(provider: joined)
        } catch {
            show(error.localizedDescription)
        }
    }

    /// How an invited person can sign in, for Settings ("Google, Apple, its password, or a passkey…").
    var cloudSignInWays: String {
        let providers = cloudConfig?.providerNames ?? []
        return (providers + ["its password"]).joined(separator: ", ") + ", or a passkey once you've added one"
    }

    /// Opens the page that saves a passkey (Touch ID / iCloud Keychain) for the next sign-ins.
    func addCloudPasskey(retry: Bool = true) async {
        guard let account = cloudAccount else { return }
        do {
            let callback = try await WebSignIn.shared.open(account.addPasskeyURL)
            let result = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "result" }?.value
            switch result {
            case "invalid_session" where retry:
                // The hosted page needs a fresh sign-in first; then it offers the passkey straight away.
                await signInToCloud()
                if cloudSignedIn { await addCloudPasskey(retry: false) }
            case nil, "success":
                show("Passkey saved. Next time, sign in with Touch ID.")
            default:
                show("The passkey wasn't saved (\(result ?? "unknown")).")
            }
        } catch is CancellationError {
        } catch {
            show(error.localizedDescription)
        }
    }

    func signOutOfCloud() async {
        await cloudAccount?.signOut()
        settings.cloudBrowser = false
        cloudTest = nil
        show("Signed out of the cloud browser.")
    }

    /// Starts Chrome in the cloud, opens LinkedIn with the sign-in made there, and reports what it saw.
    func testCloud() async {
        guard let account = cloudAccount else { return }
        cloudBusy = "Starting Chrome in the cloud…"
        cloudTest = nil
        defer { cloudBusy = nil }
        let started = Date()
        do {
            let cloud = try await CloudBrowser.start(account: account, timeout: 900)
            let ready = Date().timeIntervalSince(started)
            let agent = WebAgent(cloud: cloud)
            cloudBusy = "Opening LinkedIn…"
            let recognized = await agent.linkedInSignedIn()
            let image = await agent.snapshot()
            await cloud.stop(saveProfile: recognized)
            agent.close()
            settings.cloudLinkedIn = recognized
            let start = "Working: Chrome started in \(String(format: "%.1f", ready)) s"
            var message = recognized ? "\(start) and LinkedIn recognized you." : "\(start). Sign in to LinkedIn in it (Settings › LinkedIn) before a run."
            let ai = await checkCloudHelper()
            if let ai { message += " " + ai.message }
            cloudTest = CloudTest(ok: ai?.ok ?? true, message: message, image: image)
        } catch {
            cloudTest = CloudTest(ok: false, message: error.localizedDescription, image: nil)
        }
    }

    /// Asks the cloud AI one made-up question with this sign-in's credentials, the way runs do (nil when it's off).
    private func checkCloudHelper() async -> (ok: Bool, message: String)? {
        guard settings.ai.cloudHelper, let helper = makeCloudHelper() else { return nil }
        cloudBusy = "Asking the cloud AI…"
        let started = Date()
        do {
            let reply = try await helper.model.generate(instructions: "Answer the question with a number.", prompt: "What is 2 + 3?",
                                                        schema: .object([("answer", .number)]))
            guard reply["answer"] != nil else { return (false, "The cloud AI's reply was empty.") }
            return (true, "\(helper.displayName) answered in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
        } catch {
            return (false, "The cloud AI didn't answer: \(error.localizedDescription)")
        }
    }

    /// The browser a run uses: Chrome in the cloud when that's on (with the LinkedIn sign-in made inside it; one copied
    /// from this Mac gets ended by LinkedIn once it shows up far away), else the built-in one.
    func makeRunBrowser() async throws -> WebAgent {
        guard usesCloud, let account = cloudAccount else { return web }
        runPhase = "Starting Chrome in the cloud"
        let minutes = Double(settings.limits.maxAppliesPerRun) * 6
        let cloud = try await CloudBrowser.start(account: account, timeout: min(8 * 3600, max(3600, minutes * 60)))
        return WebAgent(cloud: cloud)
    }

    /// Starts the cloud browser for signing in to LinkedIn inside it, without an old LinkedIn sign-in.
    func startCloudLinkedInSignIn() async throws -> CloudBrowser {
        guard let account = cloudAccount else { throw BrowserError("The cloud browser isn't set up.") }
        let cloud = try await CloudBrowser.start(account: account, timeout: 1800)
        signInCloud = cloud
        await cloud.clearCookies(domain: "linkedin.com")
        return cloud
    }

    /// Ends the sign-in session; with `signedIn`, keeps its cookies for runs.
    func finishCloudLinkedInSignIn(_ cloud: CloudBrowser, signedIn: Bool) async {
        if signInCloud === cloud { signInCloud = nil }
        await cloud.stopScreencast()
        await cloud.stop(saveProfile: signedIn)
        if signedIn {
            settings.cloudLinkedIn = true
            show("Signed in to LinkedIn in the cloud browser.")
        }
    }

    /// Removes the LinkedIn sign-in from the cloud browser.
    func signOutOfCloudLinkedIn() async {
        guard let account = cloudAccount else { return }
        cloudBusy = "Signing out of LinkedIn…"
        defer { cloudBusy = nil }
        do {
            let cloud = try await CloudBrowser.start(account: account, timeout: 900)
            await cloud.clearCookies(domain: "linkedin.com")
            await cloud.stop(saveProfile: true)
            settings.cloudLinkedIn = false
            show("Signed out of LinkedIn.")
        } catch {
            show(error.localizedDescription)
        }
    }
}

struct CloudTest {
    var ok: Bool
    var message: String
    var image: NSImage?
}

/// The system sign-in sheet (Safari's engine, so passkeys from iCloud Keychain and Touch ID work).
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebSignIn()
    private var session: ASWebAuthenticationSession?

    /// Shows `url` until the page returns to the app; returns that address.
    func open(_ url: URL) async throws -> URL {
        session?.cancel()
        return try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: CloudConfig.callbackScheme) { callback, error in
                if let callback {
                    cont.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    cont.resume(throwing: CancellationError())
                } else {
                    cont.resume(throwing: error ?? CloudError.failed("The sign-in window closed."))
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false  // keep the hosted page's session for "Add a passkey"
            session = s
            if !s.start() { cont.resume(throwing: CloudError.failed("The sign-in window couldn't open.")) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey } ?? ASPresentationAnchor() }
    }
}

/// Settings › Cloud browser.
struct CloudBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.blueWash)
                    Image(systemName: "cloud.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.blue)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    if model.cloudSignedIn {
                        Text(model.secrets.cloudEmail.isEmpty ? "Signed in" : model.secrets.cloudEmail).font(Typo.bodyStrong)
                        Text("Stays signed in for 30 days, then asks once more.").font(Typo.small).foregroundStyle(Palette.textSoft)
                    } else {
                        Text("Not signed in").font(Typo.bodyStrong)
                        Text("Pages can load in Chrome on Amazon Web Services instead of on this Mac. It's invite-only: sign in with the address you were invited with, using \(model.cloudSignInWays).")
                            .font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if model.cloudSignedIn {
                    Button("Sign out") { Task { await model.signOutOfCloud() } }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Sign in") { Task { await model.signInToCloud() } }.buttonStyle(PrimaryButtonStyle())
                }
            }
            if model.cloudSignedIn {
                Divider().overlay(Palette.line)
                ToggleRow(title: "Use the cloud browser for runs",
                          detail: "This Mac still directs each run, so keep it awake. Your LinkedIn sign-in is carried over; nothing is recorded.",
                          isOn: $model.settings.cloudBrowser)
                if model.cloudHelperAvailable {
                    ToggleRow(title: "Ask the cloud AI what the on-device AI can't answer",
                              detail: "On runs in the cloud browser, questions the on-device AI isn't sure about go to \(model.cloudConfig?.helperName ?? "a stronger model") in your AWS account, with your profile minus your email and phone. Its answers follow the same rules (cite your profile, or ask you), are saved, and help the on-device AI from then on.",
                              isOn: $model.settings.ai.cloudHelper)
                        .disabled(!model.settings.cloudBrowser)
                        .opacity(model.settings.cloudBrowser ? 1 : 0.5)
                }
                HStack(spacing: 8) {
                    Button("Test it") { Task { await model.testCloud() } }.buttonStyle(SecondaryButtonStyle())
                    Button("Add a passkey") { Task { await model.addCloudPasskey() } }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
                if let test = model.cloudTest {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = test.image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 168)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line))
                        }
                        Label(test.message, systemImage: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(Typo.small).foregroundStyle(test.ok ? Palette.greenDeep : Palette.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let busy = model.cloudBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(Typo.small).foregroundStyle(Palette.textSoft)
                }
            }
        }
        .disabled(model.isRunning || model.cloudBusy != nil)
    }
}

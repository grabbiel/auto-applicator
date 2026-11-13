import AppKit
import UniformTypeIdentifiers
import WebKit

public struct BrowserError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Drives a WebKit view the way a person would: real (trusted) mouse clicks and keystrokes delivered to its window,
/// values set from an isolated script world (so React/Vue/Angular see them as user input), files attached through
/// the page's own file inputs. It uses the system's WebKit — nothing to download, no browser window, and it is
/// stopped together with the app.
///
/// The view lives in an off-screen window while it works; the Live page can borrow it to show what's happening.
@MainActor
public final class WebAgent: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    private let hostWindow: NSWindow
    private var eventNumber = 1
    /// Called when the page asks to open a new window (a link with target=_blank, window.open).
    public var popupOpened: ((URL) -> Void)?
    public private(set) var lastNavigationError: String?
    /// Set when this agent drives the cloud browser instead of the built-in one (see CloudBrowser).
    public let cloud: CloudBrowser?

    public static let viewport = NSSize(width: 1280, height: 900)

    public init(cloud: CloudBrowser? = nil) {
        self.cloud = cloud
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 14.0, *) {
            // Keep timers and rendering at full speed while the view is off screen.
            config.preferences.inactiveSchedulingPolicy = .none
        }
        config.applicationNameForUserAgent = "Version/\(WebAgent.safariVersion) Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.viewport), configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        // The window is on screen but fully transparent and click-through: WebKit then treats the page as visible
        // (an off-screen window makes it "hidden", which pauses animation frames and breaks many sites).
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        hostWindow = NSWindow(contentRect: NSRect(origin: origin, size: Self.viewport), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        hostWindow.isReleasedWhenClosed = false
        hostWindow.isExcludedFromWindowsMenu = true
        hostWindow.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        hostWindow.alphaValue = 0
        hostWindow.hasShadow = false
        hostWindow.ignoresMouseEvents = true
        hostWindow.canHide = false
        hostWindow.contentView = webView
        hostWindow.orderBack(nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        cloud?.popupOpened = { [weak self] url in self?.popupOpened?(url) }
    }

    /// Takes the view out of its hidden window so the app can show it (the LinkedIn sign-in sheet). `reclaim()` puts
    /// it back.
    public func lend() -> WKWebView {
        if webView.window === hostWindow { hostWindow.contentView = NSView(frame: NSRect(origin: .zero, size: Self.viewport)) }
        return webView
    }

    /// Puts the view back into its off-screen window (after the sign-in sheet showed it).
    public func reclaim() {
        guard webView.window !== hostWindow else { return }
        webView.removeFromSuperview()
        webView.frame = NSRect(origin: .zero, size: Self.viewport)
        hostWindow.contentView = webView
    }

    public var isShownToUser: Bool { webView.window !== hostWindow && webView.window != nil }

    static let safariVersion: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: plist), let v = dict["CFBundleShortVersionString"] as? String { return v }
        return "18.0"
    }()

    public func close() {
        if let cloud { cloud.stopBeforeExit() }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        hostWindow.orderOut(nil)
        hostWindow.close()
    }

    // MARK: navigation

    public var url: URL? { cloud != nil ? cloud?.url : webView.url }
    private var isLoading: Bool { cloud?.isLoading ?? webView.isLoading }

    /// Ends a cloud session properly (saving its cookies); for the built-in browser, the same as `close()`.
    public func finish() async {
        if let cloud { await cloud.stop() }
        close()
    }

    /// Stops whatever the page is loading.
    public func stopLoading() {
        if let cloud { Task { try? await cloud.call("Page.stopLoading") } } else { webView.stopLoading() }
    }

    public func load(_ url: URL, timeout: TimeInterval = 30) async throws {
        lastNavigationError = nil
        if let cloud {
            lastNavigationError = try await cloud.navigate(url)
        } else {
            webView.load(URLRequest(url: url))
        }
        try await waitForLoad(timeout: timeout)
    }

    /// Waits until the page has parsed its document (like DOMContentLoaded) and redirects have settled.
    public func waitForLoad(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await sleep(0.3)
        while Date() < deadline {
            try Task.checkCancellation()
            if let state = try? await js("return document.readyState") as? String, state != "loading", url != nil {
                if !isLoading || state == "complete" || Date().addingTimeInterval(timeout - 8) > deadline { return }
            }
            try await sleep(0.25)
        }
        if let err = lastNavigationError { throw BrowserError(err) }
    }

    public func reload() async throws {
        if let cloud { try await cloud.reload() } else { webView.reload() }
        try await waitForLoad()
    }

    public func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordFailure(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordFailure(error)
    }

    private func recordFailure(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }  // frame load interrupted (a download or redirect)
        lastNavigationError = error.localizedDescription
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                                    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Never hand links to other apps (mailto:, app links): stay in the page. Local files only when the app
        // itself opens one (tests), never from a link on a page.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let allowed = ["http", "https", "about", "blob", "data"].contains(scheme) || (scheme == "file" && navigationAction.navigationType == .other)
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                                    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    /// New windows open in this same view (one page at a time is all the automation needs).
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                                    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            webView.load(URLRequest(url: url))
            popupOpened?(url)
        }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                                    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                                    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(true)
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                                    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(defaultText)
    }

    // MARK: scripts

    /// Runs a function body in the automation's own script world (the page can't see or tamper with it) and
    /// returns its result. `args` become variables of the same names.
    @discardableResult
    public func js(_ body: String, _ args: [String: Any] = [:], world: WKContentWorld? = nil) async throws -> Any? {
        if let cloud { return try await cloud.run(body, args, pageWorld: world == .page) }
        let world = world ?? .defaultClient
        let wrapped = "const __r = await (async () => { \(body) })(); return __r === undefined ? null : __r;"
        let result: Any = try await withCheckedThrowingContinuation { cont in
            webView.callAsyncJavaScript(wrapped, arguments: args, in: nil, in: world) { result in
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
        return result is NSNull ? nil : result
    }

    @discardableResult
    public func bool(_ body: String, _ args: [String: Any] = [:]) async -> Bool {
        ((try? await js(body, args)) as? Bool) ?? false
    }

    public func string(_ body: String, _ args: [String: Any] = [:]) async -> String {
        ((try? await js(body, args)) as? String) ?? ""
    }

    public func exists(_ selector: String) async -> Bool {
        await bool("try { return !!document.querySelector(sel); } catch (e) { return false; }", ["sel": selector])
    }

    public func isVisible(_ selector: String) async -> Bool {
        await bool(Scripts.prelude + "try { return [...document.querySelectorAll(sel)].some(shown); } catch (e) { return false; }", ["sel": selector])
    }

    /// Waits for an element to exist (and be visible, if asked).
    @discardableResult
    public func waitFor(_ selector: String, visible: Bool = false, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if visible ? await isVisible(selector) : await exists(selector) { return true }
            try? await sleep(0.25)
        }
        return false
    }

    public func text(maxChars: Int = 6000) async -> String {
        String(await string("return document.body ? document.body.innerText : ''").prefix(maxChars))
    }

    // MARK: input

    /// The center of the first visible element matching `selector`, scrolled into view, in view coordinates
    /// (top-left origin), and whether something else covers that point.
    private func target(_ selector: String) async -> (CGPoint, covered: Bool)? {
        let r = try? await js(Scripts.prelude + """
            let el = null;
            try { el = [...document.querySelectorAll(sel)].find(shown) || document.querySelector(sel); } catch (e) { return null; }
            if (!el) return null;
            el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
            await new Promise(r => setTimeout(r, 40));
            const b = el.getBoundingClientRect();
            if (b.width <= 0 || b.height <= 0) return null;
            const x = b.left + Math.min(b.width / 2, 40), y = b.top + b.height / 2;
            const hit = document.elementFromPoint(x, y);
            const label = el.labels && el.labels[0];
            const ok = hit && (hit === el || el.contains(hit) || hit.contains(el) || (label && (label === hit || label.contains(hit))));
            return {x, y, covered: !ok};
            """, ["sel": selector]) as? [String: Any]
        guard let r, let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue else { return nil }
        return (CGPoint(x: x, y: y), (r["covered"] as? Bool) ?? false)
    }

    private func windowPoint(_ p: CGPoint) -> NSPoint? {
        guard webView.window != nil else { return nil }
        let inView = NSPoint(x: p.x, y: webView.isFlipped ? p.y : webView.bounds.height - p.y)
        return webView.convert(inView, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1) {
        guard let window = webView.window else { return }
        eventNumber += 1
        if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
                                      pressure: type == .leftMouseUp ? 0 : 1) {
            window.sendEvent(e)
        }
    }

    /// Clicks an element like a person: moves there and presses the mouse button. Falls back to a script click
    /// when the element is covered or the click didn't land.
    @discardableResult
    public func click(_ selector: String) async -> Bool {
        guard let (p, covered) = await target(selector) else { return false }
        if !covered, cloud != nil || webView.window != nil {
            await bool("try { const el = document.querySelector(sel); if (el) el.__aaClicked = false; " +
                       "if (el) el.addEventListener('click', e => { el.__aaClicked = true; }, {once: true, capture: true}); return true; } catch (e) { return false; }",
                       ["sel": selector])
            if let cloud {
                try? await cloud.click(at: p)
            } else if let wp = windowPoint(p) {
                mouse(.mouseMoved, at: wp)
                mouse(.leftMouseDown, at: wp)
                try? await sleep(0.06)
                mouse(.leftMouseUp, at: wp)
            }
            try? await sleep(0.05)
            if await bool("try { const el = document.querySelector(sel); return !el || !el.isConnected || el.__aaClicked !== false; } catch (e) { return true; }",
                          ["sel": selector]) {
                return true
            }
        }
        return await bool("""
            let el = null; try { el = document.querySelector(sel); } catch (e) {}
            if (!el) return false;
            const target = (el.tagName === 'INPUT' && el.labels && el.labels[0] && getComputedStyle(el).opacity === '0') ? el.labels[0] : el;
            for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) target.dispatchEvent(new MouseEvent(t, {bubbles: true, cancelable: true, view: window}));
            target.click();
            return true;
            """, ["sel": selector])
    }

    /// Sets a text field's value the way typing would (input and change events, framework-visible).
    @discardableResult
    public func fill(_ selector: String, _ value: String, keepFocus: Bool = false) async -> Bool {
        _ = await target(selector)
        return await bool(Scripts.setValue, ["sel": selector, "value": value, "keepFocus": keepFocus])
    }

    public func selectOption(_ selector: String, label: String) async -> Bool {
        await bool(Scripts.selectOption, ["sel": selector, "label": label])
    }

    public func isChecked(_ selector: String) async -> Bool {
        await bool("try { const el = document.querySelector(sel); return !!(el && (el.checked || el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-pressed') === 'true')); } catch (e) { return false; }",
                   ["sel": selector])
    }

    /// Presses a key in the focused element: real key events, with a script fallback.
    public func press(_ key: Key, selector: String? = nil) async {
        if let selector { await bool("try { const el = document.querySelector(sel); if (el) el.focus(); return true; } catch (e) { return false; }", ["sel": selector]) }
        if let cloud, (try? await cloud.press(key)) != nil {
            try? await sleep(0.05)
            return
        }
        if cloud == nil, let window = webView.window, window === hostWindow || window.isKeyWindow {
            window.makeFirstResponder(webView)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) {
                    window.sendEvent(e)
                }
            }
            try? await sleep(0.05)
            return
        }
        await bool("""
            const el = document.activeElement || document.body;
            for (const t of ['keydown', 'keyup']) el.dispatchEvent(new KeyboardEvent(t, {key: k, code: k, bubbles: true, cancelable: true}));
            return true;
            """, ["k": key.domName])
    }

    public enum Key {
        case enter, escape, tab, down, up
        var code: UInt16 { switch self { case .enter: 36; case .escape: 53; case .tab: 48; case .down: 125; case .up: 126 } }
        var characters: String {
            switch self {
            case .enter: "\r"; case .escape: "\u{1b}"; case .tab: "\t"
            case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!); case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
            }
        }
        var domName: String { switch self { case .enter: "Enter"; case .escape: "Escape"; case .tab: "Tab"; case .down: "ArrowDown"; case .up: "ArrowUp" } }
    }

    /// Attaches files to an <input type=file> (the page receives them exactly as if the user had picked them).
    public func setFiles(_ selector: String, _ files: [URL]) async -> Bool {
        var payload: [[String: String]] = []
        for url in files {
            guard let data = try? Data(contentsOf: url), data.count <= 25 << 20 else { return false }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            payload.append(["name": url.lastPathComponent, "type": mime, "data": data.base64EncodedString()])
        }
        return await bool(Scripts.setFiles, ["sel": selector, "files": payload])
    }

    // MARK: evidence

    /// The whole page as a PDF (searchable text, every part of a long form).
    public func pdf() async -> Data? {
        if let cloud { return await cloud.pdf() }
        return await withCheckedContinuation { cont in
            webView.createPDF { result in cont.resume(returning: try? result.get()) }
        }
    }

    public func snapshot() async -> NSImage? {
        if let cloud { return await cloud.screenshot() }
        return await withCheckedContinuation { cont in
            webView.takeSnapshot(with: nil) { image, _ in cont.resume(returning: image) }
        }
    }

    // MARK: cookies

    public func cookies(for domain: String) async -> [HTTPCookie] {
        if let cloud { return await cloud.cookies(for: domain) }
        return await Self.storedCookies(for: domain)
    }

    /// The built-in browser's cookies for `domain` (its sign-ins), without creating a browser.
    public static func storedCookies(for domain: String) async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies.filter { $0.domain.hasSuffix(domain) })
            }
        }
    }

    /// Forgets every site's cookies and storage (used by "Sign out of LinkedIn").
    public static func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

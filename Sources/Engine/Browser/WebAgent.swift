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
    /// Site checks only (never set in the app): asked before each click with what is about to be pressed
    /// ("button: Create account", "input checkbox: I agree") and its selector; false leaves it unpressed.
    public var willPress: ((_ what: String, _ selector: String) async -> Bool)?
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
        // The window sits behind the person's own windows, and a covered window counts as hidden: WebKit then stops
        // drawing the page (no animation frames), and pages drawn by web components never appear (ADP's job pages
        // stayed blank). WebKit's own switch (not public API) keeps it drawing.
        if webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:"))) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
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
        } else if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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
            // "complete|about:blank" is the empty page a new browser starts on, before the real one arrives.
            if let r = try? await js("return document.readyState + '|' + location.href") as? String, let url {
                let parts = r.split(separator: "|", maxSplits: 1).map(String.init)
                let state = parts.first ?? "", href = parts.count > 1 ? parts[1] : ""
                let blank = href == "about:blank" && url.absoluteString != "about:blank"
                if state != "loading", !blank, !isLoading || state == "complete" || Date().addingTimeInterval(timeout - 8) > deadline { return }
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
        let wrapped = Scripts.deepDocument + "\nconst __r = await (async () => { \(body) })(); return __r === undefined ? null : __r;"
        let result: Result<Any, Error> = await Self.callback(within: Self.scriptTimeLimit, orElse: .failure(PageNotAnswering())) { done in
            webView.callAsyncJavaScript(wrapped, arguments: args, in: nil, in: world) { result in done(result) }
        }
        let value = try result.get()
        return value is NSNull ? nil : value
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

    /// The page's visible text, starting with what's drawn inside open shadow roots (such as LinkedIn's Easy Apply
    /// window), which the body's text leaves out.
    public func text(maxChars: Int = 6000) async -> String {
        String(await string(#"""
            const parts = [];
            const walk = node => {
              for (const el of node.querySelectorAll('*')) {
                if (!el.shadowRoot) continue;
                for (const c of el.shadowRoot.children) {
                  if (/^(style|script|link|template|svg)$/i.test(c.tagName) || !c.getClientRects().length || getComputedStyle(c).visibility === 'hidden') continue;
                  const t = (c.innerText || '').trim();
                  if (t) parts.push(t);
                }
                walk(el.shadowRoot);
              }
            };
            walk(window.document);
            const body = window.document.body ? window.document.body.innerText : '';
            return parts.length ? parts.join('\n') + '\n' + body : body;
            """#).prefix(maxChars))
    }

    // MARK: input

    /// The center of the first visible element matching `selector`, scrolled into view, in view coordinates
    /// (top-left origin), and whether something else covers that point. A checkbox or radio the page draws itself
    /// (the real box zero-size or transparent, as on Oracle's career sites) is aimed at where it's drawn: a small box
    /// inside its label, else the label's left edge. `document.__aaAim` remembers what the click is aimed at.
    private func target(_ selector: String) async -> (CGPoint, covered: Bool)? {
        let r = try? await js(Scripts.prelude + """
            document.__aaAim = null;
            let el = null;
            try { el = [...document.querySelectorAll(sel)].find(shown) || document.querySelector(sel); } catch (e) { return null; }
            if (!el) return null;
            const label = el.labels && el.labels[0];
            let aim = el;
            // A hidden radio inside the choice people press (Rippling's): that choice.
            // (Radix's copy sits out of reach, see-through and aria-hidden, just after its button: that button.)
            if (!label && (!shown(el) || el.getAttribute('aria-hidden') === 'true') && shown(ariaChoice(el))) aim = ariaChoice(el);
            if (el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type) && label) {
              const r0 = el.getBoundingClientRect();
              if (r0.width < 4 || r0.height < 4 || getComputedStyle(el).opacity === '0') {
                const box = [...label.querySelectorAll('*')].find(c => {
                  if (c === el || c.closest('a, button')) return false;
                  const b = c.getBoundingClientRect();
                  return b.width >= 8 && b.height >= 8 && b.width <= 48 && b.height <= 48 && Math.abs(b.width - b.height) <= 8;
                });
                aim = box || label;
              }
            }
            // A choice in an open list only as far as needed: a list that draws only the rows in view redraws them when
            // it scrolls, and the tagged row would be gone.
            const nearest = el.hasAttribute('data-auto-choice');
            aim.scrollIntoView({block: nearest ? 'nearest' : 'center', inline: nearest ? 'nearest' : 'center', behavior: 'instant'});
            await new Promise(r => setTimeout(r, 40));
            const b = aim.getBoundingClientRect();
            if (b.width <= 0 || b.height <= 0) return null;
            document.__aaAim = aim;
            const x = b.left + Math.min(b.width / 2, aim === label && aim !== el ? 10 : 40), y = b.top + b.height / 2;
            const hit = document.elementFromPoint(x, y);
            const ok = hit && (hit === aim || aim.contains(hit) || hit.contains(aim) || hit === el || (label && (label === hit || label.contains(hit))));
            // Inside a frame (see Scripts.deepDocument): where the frame sits on the page.
            const o = __aaFrame ? __aaFrame.getBoundingClientRect() : {left: 0, top: 0};
            const ox = __aaFrame ? o.left + __aaFrame.clientLeft : 0, oy = __aaFrame ? o.top + __aaFrame.clientTop : 0;
            return {x: x + ox, y: y + oy, covered: !ok};
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
        if let willPress {
            let what = await string(Scripts.prelude + """
                const el = document.querySelector(sel); if (!el) return '';
                const name = (el.getAttribute('aria-label') || words(el) || el.title || '').replace(/\\s+/g, ' ').trim();
                const label = el.labels && el.labels[0] ? el.labels[0].innerText.replace(/\\s+/g, ' ').trim() : '';
                return el.tagName.toLowerCase() + (el.type ? ' ' + el.type : '') + (el.getAttribute('role') ? ' ' + el.getAttribute('role') : '')
                    + ': ' + (name || label).slice(0, 120);
                """, ["sel": selector])
            guard await willPress(what, selector) else { return false }
        }
        // Without a point to press (a zero-size element), the script click below still works.
        if let (p, covered) = await target(selector), !covered, cloud != nil || webView.window != nil {
            let aimed = "(document.__aaAim && document.__aaAim.isConnected ? document.__aaAim : document.querySelector(sel))"
            await bool("try { const el = \(aimed); if (el) el.__aaClicked = false; " +
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
            if await bool("try { const el = \(aimed); return !el || !el.isConnected || el.__aaClicked !== false; } catch (e) { return true; }",
                          ["sel": selector]) {
                return true
            }
        }
        return await scriptClick(selector)
    }

    /// A click sent to the element by script: no mouse moves and the focus stays where it is (a list that closes when
    /// its box loses the focus keeps its choices).
    @discardableResult
    public func scriptClick(_ selector: String) async -> Bool {
        await bool("""
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
        if await bool(Scripts.selectOption, ["sel": selector, "label": label]) { return true }
        // A list the page draws from its own state (Toyota's Phenom "Device Type"): it shows the old choice for a moment,
        // then the new one.
        try? await sleep(0.4)
        return await bool("""
            let el = null; try { el = document.querySelector(sel); } catch (e) {}
            if (!el || el.tagName !== 'SELECT' || el.selectedIndex < 0) return false;
            const n = s => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            const o = el.options[el.selectedIndex];
            return !!n(label) && (n(o.text) === n(label) || n(o.value) === n(label));
            """, ["sel": selector, "label": label])
    }

    public func isChecked(_ selector: String) async -> Bool {
        await bool(Scripts.prelude + "try { const el = document.querySelector(sel); const c = ariaChoice(el); return !!(el && (el.checked || el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-pressed') === 'true' || (c && c.getAttribute('aria-checked') === 'true'))); } catch (e) { return false; }",
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

    /// Types text where the focus is, one character at a time as a keyboard does (for boxes that take one character
    /// each and move on to the next as you type). False when there's no keyboard to type with.
    @discardableResult
    public func typeKeys(_ text: String) async -> Bool {
        if let cloud {
            for ch in text {
                await cloud.typeKey(ch)
                try? await sleep(0.08)
            }
            return true
        }
        guard let window = webView.window, window === hostWindow || window.isKeyWindow else { return false }
        window.makeFirstResponder(webView)
        for ch in text {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                            charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) {
                    window.sendEvent(e)
                }
            }
            try? await sleep(0.08)
        }
        return true
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
        return await Self.callback(within: 30, orElse: nil) { done in
            webView.createPDF { result in done(try? result.get()) }
        }
    }

    public func snapshot() async -> NSImage? {
        if let cloud { return await cloud.screenshot() }
        return await Self.callback(within: 20, orElse: nil) { done in
            webView.takeSnapshot(with: nil) { image, _ in done(image) }
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

    /// How long a script may run in the page before the app stops waiting for it.
    static let scriptTimeLimit: TimeInterval = 60

    /// A page that stopped answering the app's scripts (twonice's Trakstar page once never did, which held the run).
    public struct PageNotAnswering: LocalizedError {
        public var errorDescription: String? { "The page stopped responding" }
    }

    /// Waits for a WebKit callback, but no longer than `seconds` (then `fallback`): a page whose script never returns, or
    /// that stopped drawing, would otherwise hold the whole run, which cancelling can't end.
    static func callback<T>(within seconds: TimeInterval, orElse fallback: T, _ start: (@escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            var finished = false
            let finish: (T) -> Void = { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            start(finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { finish(fallback) } }
        }
    }

    /// Forgets every site's cookies and storage (used by "Sign out of LinkedIn").
    public static func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

import AppKit
import Foundation
import PDFKit

/// A Chrome running in AWS (Amazon Bedrock AgentCore Browser), driven over the Chrome DevTools protocol.
///
/// `WebAgent(cloud:)` routes its basic operations here (scripts, navigation, mouse and keys, pictures, cookies), so
/// everything built on them — form filling, the site handlers — works the same in the cloud. Cookies are kept between
/// sessions in a browser profile; LinkedIn's are copied over from the built-in browser at the start of each session.
@MainActor
public final class CloudBrowser {
    public let config: CloudConfig
    private let credentials: @Sendable () async throws -> AWSCredentials
    public private(set) var sessionId: String?
    private var lastCredentials: AWSCredentials?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pageSession: String?
    private var pageTarget: String?
    private var mainFrame: String?
    private var isolatedContext: Int?
    private var handledPopups: Set<String> = []
    private var responder: ((URL) -> (body: Data, mime: String)?)?

    public private(set) var url: URL?
    public private(set) var isLoading = false
    /// The page opened a new window; its address loads in the main page (the same as the built-in browser).
    var popupOpened: ((URL) -> Void)?

    private init(config: CloudConfig, credentials: @escaping @Sendable () async throws -> AWSCredentials) {
        self.config = config
        self.credentials = credentials
    }

    private var endpoint: URL { URL(string: "https://bedrock-agentcore.\(config.region).amazonaws.com")! }

    // MARK: session

    /// Starts a session (ending on its own after `timeout` at the latest) and attaches to its page.
    public static func start(account: CloudAccount, timeout: TimeInterval = 3600) async throws -> CloudBrowser {
        try await start(config: account.config, credentials: { try await account.credentials() }, timeout: timeout)
    }

    /// The same with any source of credentials (tests use an administrator's, and leave the saved cookies alone).
    public static func start(config: CloudConfig, credentials: @escaping @Sendable () async throws -> AWSCredentials,
                             timeout: TimeInterval = 3600, useProfile: Bool = true) async throws -> CloudBrowser {
        let browser = CloudBrowser(config: config, credentials: credentials)
        try await browser.open(timeout: timeout, useProfile: useProfile)
        return browser
    }

    private func open(timeout: TimeInterval, useProfile: Bool) async throws {
        var body: [String: Any] = [
            "name": "auto-applicator",
            "sessionTimeoutSeconds": Int(min(28_800, max(900, timeout))),
            "viewPort": ["width": Int(WebAgent.viewport.width), "height": Int(WebAgent.viewport.height)],
        ]
        if useProfile { body["profileConfiguration"] = ["profileIdentifier": config.browserProfileId] }
        let r = try await rest("PUT", "/browsers/\(config.browserId)/sessions/start", body: body)
        guard let id = r["sessionId"] as? String,
              let stream = ((r["streams"] as? [String: Any])?["automationStream"] as? [String: Any])?["streamEndpoint"] as? String,
              let streamURL = URL(string: stream) else {
            throw BrowserError("The cloud browser didn't start.")
        }
        sessionId = id
        Log.info("Cloud browser session \(id) started")
        do {
            try await connect(streamURL)
            try await attachToPage()
        } catch {
            await stop(saveProfile: false)
            throw error
        }
    }

    private func connect(_ streamURL: URL) async throws {
        var request = URLRequest(url: streamURL)
        let creds = try await credentials()
        lastCredentials = creds
        SigV4(credentials: creds, region: config.region, service: "bedrock-agentcore").sign(&request)
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20  // screenshots, PDFs and resume uploads are base64
        socket = task
        task.resume()
        receiveTask = Task { [weak self] in
            while let socket = self?.socket {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let s): self?.dispatch(Data(s.utf8))
                    case .data(let d): self?.dispatch(d)
                    @unknown default: break
                    }
                } catch {
                    self?.disconnected()
                    return
                }
            }
        }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.socket?.sendPing { _ in }
            }
        }
    }

    private func attachToPage() async throws {
        _ = try await call("Target.setDiscoverTargets", ["discover": true], onPage: false)
        let targets = (try await call("Target.getTargets", onPage: false)["targetInfos"] as? [[String: Any]]) ?? []
        var target = targets.first { $0["type"] as? String == "page" }?["targetId"] as? String
        if target == nil { target = try await call("Target.createTarget", ["url": "about:blank"], onPage: false)["targetId"] as? String }
        guard let target else { throw BrowserError("The cloud browser has no page.") }
        pageTarget = target
        pageSession = try await call("Target.attachToTarget", ["targetId": target, "flatten": true], onPage: false)["sessionId"] as? String
        guard pageSession != nil else { throw BrowserError("Couldn't attach to the cloud browser's page.") }
        _ = try await call("Page.enable")
        let tree = try await call("Page.getFrameTree")
        if let frame = (tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any] {
            mainFrame = frame["id"] as? String
            url = (frame["url"] as? String).flatMap(URL.init(string:))
        }
    }

    /// Saves the cookies to the profile (unless told not to) and ends the session. Safe to call more than once.
    public func stop(saveProfile: Bool = true) async {
        guard let id = sessionId else { return }
        sessionId = nil
        if saveProfile {
            do {
                _ = try await rest("PUT", "/browser-profiles/\(config.browserProfileId)/save",
                                   body: ["browserIdentifier": config.browserId, "sessionId": id])
            } catch {
                Log.warn("Couldn't save the cloud browser's cookies: \(error.localizedDescription)")
            }
        }
        do {
            _ = try await rest("PUT", "/browsers/\(config.browserId)/sessions/stop", query: [.init(name: "sessionId", value: id)], body: [:])
            Log.info("Cloud browser session \(id) stopped")
        } catch {
            Log.warn("Couldn't stop cloud browser session \(id): \(error.localizedDescription)")
        }
        closeSocket()
    }

    /// For quitting: ends the session within `timeout` without awaiting (the app is about to exit).
    public func stopBeforeExit(timeout: TimeInterval = 2) {
        guard let id = sessionId, let creds = lastCredentials, creds.isFresh else { closeSocket(); return }
        sessionId = nil
        var c = URLComponents(url: endpoint.appendingPathComponent("browsers/\(config.browserId)/sessions/stop"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "sessionId", value: id)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "PUT"
        req.httpBody = Data(#"{"clientToken":"\#(UUID().uuidString)"}"#.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        SigV4(credentials: creds, region: config.region, service: "bedrock-agentcore").sign(&req)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + timeout)
        closeSocket()
    }

    private func closeSocket() {
        keepAliveTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAll(BrowserError("The cloud browser closed."))
    }

    private func disconnected() {
        guard socket != nil else { return }
        Log.warn("Cloud browser connection closed")
        socket = nil
        keepAliveTask?.cancel()
        failAll(BrowserError("The cloud browser disconnected (the session may have timed out)."))
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting { cont.resume(throwing: error) }
    }

    // MARK: AWS API

    private func rest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]) async throws -> [String: Any] {
        var c = URLComponents(url: endpoint.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        var body = body
        if method != "GET" { body["clientToken"] = UUID().uuidString }  // idempotency token (the AWS SDKs add one)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let creds = try await credentials()
        lastCredentials = creds
        SigV4(credentials: creds, region: config.region, service: "bedrock-agentcore").sign(&req)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = json["message"] as? String ?? json["Message"] as? String ?? "HTTP \(status)"
            throw BrowserError("The cloud browser refused: \(message)")
        }
        return json
    }

    // MARK: DevTools protocol

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], onPage: Bool = true, timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard let socket else { throw BrowserError("The cloud browser isn't connected.") }
        let id = nextId
        nextId += 1
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if onPage, let pageSession { message["sessionId"] = pageSession }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                pending[id] = cont
                socket.send(.string(text)) { error in
                    if let error { Task { @MainActor in self.fail(id, error) } }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.fail(id, BrowserError("The cloud browser didn't answer (\(method))."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(id, CancellationError()) }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func dispatch(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = obj["id"] as? Int {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error = obj["error"] as? [String: Any] {
                cont.resume(throwing: BrowserError(error["message"] as? String ?? "The cloud browser reported an error."))
            } else {
                cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let method = obj["method"] as? String else { return }
        let params = obj["params"] as? [String: Any] ?? [:]
        let onPage = obj["sessionId"] as? String == pageSession
        switch method {
        case "Page.frameStartedLoading" where onPage && params["frameId"] as? String == mainFrame:
            isLoading = true
        case "Page.frameStoppedLoading" where onPage && params["frameId"] as? String == mainFrame:
            isLoading = false
        case "Page.frameNavigated" where onPage:
            if let frame = params["frame"] as? [String: Any], frame["parentId"] == nil {
                mainFrame = frame["id"] as? String
                url = (frame["url"] as? String).flatMap(URL.init(string:))
                isolatedContext = nil
            }
        case "Page.navigatedWithinDocument" where onPage && params["frameId"] as? String == mainFrame:
            url = (params["url"] as? String).flatMap(URL.init(string:)) ?? url
        case "Fetch.requestPaused" where onPage:
            guard let id = params["requestId"] as? String else { return }
            let link = ((params["request"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
            let page = link.flatMap { responder?($0) }
            Task {
                if let page {
                    _ = try? await self.call("Fetch.fulfillRequest", ["requestId": id, "responseCode": 200, "body": page.body.base64EncodedString(),
                                                                      "responseHeaders": [["name": "Content-Type", "value": page.mime]]])
                } else {
                    _ = try? await self.call("Fetch.continueRequest", ["requestId": id])
                }
            }
        case "Page.javascriptDialogOpening" where onPage:
            // Accept alerts and confirmations, keep a prompt's default (as the built-in browser does).
            let text = params["defaultPrompt"] as? String ?? ""
            Task { try? await self.call("Page.handleJavaScriptDialog", ["accept": true, "promptText": text]) }
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page",
                  let target = info["targetId"] as? String, target != pageTarget, info["openerId"] as? String == pageTarget,
                  let link = info["url"] as? String, link.hasPrefix("http"), let popup = URL(string: link),
                  !handledPopups.contains(target) else { return }
            handledPopups.insert(target)
            Task {
                _ = try? await self.call("Target.closeTarget", ["targetId": target], onPage: false)
                _ = try? await self.call("Page.navigate", ["url": popup.absoluteString])
                self.popupOpened?(popup)
            }
        default:
            break
        }
    }

    // MARK: what WebAgent needs

    /// Starts loading `url`; returns the browser's error text if the navigation failed outright.
    func navigate(_ target: URL) async throws -> String? {
        isLoading = true
        let r = try await call("Page.navigate", ["url": target.absoluteString])
        if let error = r["errorText"] as? String, !error.isEmpty {
            isLoading = false
            return error
        }
        return nil
    }

    /// Answers the page's requests from this Mac when `responder` returns something (tests serve fixture pages this way).
    public func serve(_ responder: @escaping (URL) -> (body: Data, mime: String)?) async throws {
        self.responder = responder
        try await call("Fetch.enable", ["patterns": [["urlPattern": "*", "requestStage": "Request"]]])
    }

    /// Runs a function body in a script world of its own (as `WebAgent.js` does), or in the page's own world, and
    /// returns its result.
    func run(_ body: String, _ args: [String: Any], pageWorld: Bool = false) async throws -> Any? {
        let argJSON = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let declarations = args.keys.sorted().map { "const \($0) = __a[\"\($0)\"];" }.joined(separator: " ")
        let expression = """
            (async () => { const __a = \(argJSON); \(declarations)
            const __r = await (async () => { \(body) })(); return __r === undefined ? null : __r; })()
            """
        for attempt in 0..<2 {
            var params: [String: Any] = ["expression": expression, "awaitPromise": true, "returnByValue": true, "userGesture": true]
            if !pageWorld, let context = try? await isolatedWorld() { params["contextId"] = context }
            do {
                let r = try await call("Runtime.evaluate", params)
                if let details = r["exceptionDetails"] as? [String: Any] {
                    let exception = details["exception"] as? [String: Any]
                    throw BrowserError("Script error: \(exception?["description"] as? String ?? details["text"] as? String ?? "unknown")")
                }
                let value = (r["result"] as? [String: Any])?["value"]
                return value is NSNull ? nil : value
            } catch let error as BrowserError where attempt == 0 && error.message.contains("context") {
                isolatedContext = nil  // the page navigated in between
            }
        }
        return nil
    }

    private func isolatedWorld() async throws -> Int {
        if let isolatedContext { return isolatedContext }
        guard let mainFrame else { throw BrowserError("No page yet.") }
        let r = try await call("Page.createIsolatedWorld", ["frameId": mainFrame, "worldName": "auto-applicator", "grantUniveralAccess": true])
        guard let id = r["executionContextId"] as? Int else { throw BrowserError("No script world.") }
        isolatedContext = id
        return id
    }

    func reload() async throws {
        isLoading = true
        try await call("Page.reload")
    }

    /// A real mouse click (move, press, release) at a point in page coordinates.
    func click(at p: CGPoint) async throws {
        try await call("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": p.x, "y": p.y])
        try await call("Input.dispatchMouseEvent", ["type": "mousePressed", "x": p.x, "y": p.y, "button": "left", "buttons": 1, "clickCount": 1])
        try await Task.sleep(for: .milliseconds(60))
        try await call("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": p.x, "y": p.y, "button": "left", "buttons": 0, "clickCount": 1])
    }

    func press(_ key: WebAgent.Key) async throws {
        let (name, code, text): (String, Int, String?) = switch key {
        case .enter: ("Enter", 13, "\r")
        case .escape: ("Escape", 27, nil)
        case .tab: ("Tab", 9, nil)
        case .down: ("ArrowDown", 40, nil)
        case .up: ("ArrowUp", 38, nil)
        }
        var down: [String: Any] = ["type": text == nil ? "rawKeyDown" : "keyDown", "key": name, "code": name,
                                   "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code]
        if let text { down["text"] = text; down["unmodifiedText"] = text }
        try await call("Input.dispatchKeyEvent", down)
        try await call("Input.dispatchKeyEvent", ["type": "keyUp", "key": name, "code": name, "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code])
    }

    func screenshot() async -> NSImage? {
        guard let r = try? await call("Page.captureScreenshot", ["format": "jpeg", "quality": 70], timeout: 15),
              let b64 = r["data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    /// The page as a PDF; when the browser can't print (a visible Chrome can't), the whole page as a picture in a PDF.
    func pdf() async -> Data? {
        if let r = try? await call("Page.printToPDF", ["printBackground": true], timeout: 30),
           let b64 = r["data"] as? String, let data = Data(base64Encoded: b64) {
            return data
        }
        let metrics = try? await call("Page.getLayoutMetrics")
        let size = (metrics?["cssContentSize"] as? [String: Any]) ?? [:]
        let width = (size["width"] as? NSNumber)?.doubleValue ?? WebAgent.viewport.width
        let height = min((size["height"] as? NSNumber)?.doubleValue ?? WebAgent.viewport.height, 16_000)
        guard let r = try? await call("Page.captureScreenshot", [
            "format": "jpeg", "quality": 80, "captureBeyondViewport": true,
            "clip": ["x": 0, "y": 0, "width": width, "height": height, "scale": 1],
        ], timeout: 30),
              let b64 = r["data"] as? String, let data = Data(base64Encoded: b64), let image = NSImage(data: data),
              let page = PDFPage(image: image) else { return nil }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc.dataRepresentation()
    }

    func cookies(for domain: String) async -> [HTTPCookie] {
        guard let r = try? await call("Storage.getCookies", onPage: false), let list = r["cookies"] as? [[String: Any]] else { return [] }
        return list.compactMap { c -> HTTPCookie? in
            guard let name = c["name"] as? String, let value = c["value"] as? String, let host = c["domain"] as? String, host.hasSuffix(domain) else { return nil }
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: host, .path: c["path"] as? String ?? "/"]
            if c["secure"] as? Bool == true { props[.secure] = "TRUE" }
            if let expires = (c["expires"] as? NSNumber)?.doubleValue, expires > 0 { props[.expires] = Date(timeIntervalSince1970: expires) }
            return HTTPCookie(properties: props)
        }
    }

    /// Copies cookies in (e.g. the LinkedIn sign-in from the built-in browser).
    public func setCookies(_ cookies: [HTTPCookie]) async {
        guard !cookies.isEmpty else { return }
        let list: [[String: Any]] = cookies.map { c in
            var d: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let expires = c.expiresDate { d["expires"] = expires.timeIntervalSince1970 }
            if let policy = c.sameSitePolicy?.rawValue.capitalized { d["sameSite"] = policy }
            return d
        }
        do { try await call("Storage.setCookies", ["cookies": list], onPage: false) } catch {
            Log.warn("Couldn't copy cookies to the cloud browser: \(error.localizedDescription)")
        }
    }
}

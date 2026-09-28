import XCTest
import WebKit
@testable import Barc

@MainActor
final class ContentScriptInjectionTests: XCTestCase {
    private var server: Process?
    private var root: URL?

    override func tearDown() {
        server?.terminate()
        server = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testContentScriptMarksPasswordField() async throws {
        let port = 18765
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
        let manifest = """
        {"manifest_version":3,"name":"Probe","version":"1.0","description":"probe","host_permissions":["http://127.0.0.1/*"],"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}]}
        """
        let script = """
        document.documentElement.setAttribute("data-injected", "1");
        document.documentElement.setAttribute("data-chrome", typeof globalThis.chrome);
        document.documentElement.setAttribute("data-browser", typeof globalThis.browser);
        const runtime = (globalThis.chrome && globalThis.chrome.runtime) || (globalThis.browser && globalThis.browser.runtime);
        document.documentElement.setAttribute("data-id", runtime && runtime.id ? String(runtime.id) : "missing");
        const field = document.querySelector("input");
        if (field) field.setAttribute("data-touched", "1");
        """
        try manifest.write(to: directory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: directory.appending(path: "content.js"), atomically: true, encoding: .utf8)
        let page = directory.appending(path: "index.html")
        try #"<input type="password" id="pw" name="password">"#.write(to: page, atomically: true, encoding: .utf8)

        let http = Process()
        http.executableURL = URL(filePath: "/usr/bin/python3")
        http.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        http.currentDirectoryURL = directory
        try http.run()
        server = http

        let shared = WKWebViewConfiguration()
        shared.websiteDataStore = .default()
        let controllerConfiguration = WKWebExtensionController.Configuration(identifier: UUID())
        controllerConfiguration.webViewConfiguration = shared
        let controller = WKWebExtensionController(configuration: controllerConfiguration)
        shared.webExtensionController = controller
        let delegate = ProbeDelegate()
        controller.delegate = delegate

        let ext = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: ext)
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)

        let configuration = shared.copy() as! WKWebViewConfiguration
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        let tab = ProbeTab(webView: webView)
        delegate.tab = tab
        controller.didOpenWindow(delegate)
        controller.didOpenTab(tab)

        let loaded = expectation(description: "page")
        let watcher = ProbeNavigation(done: loaded)
        webView.navigationDelegate = watcher
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/index.html")!))
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertNil(watcher.error, watcher.error ?? "")

        try await Task.sleep(for: .milliseconds(800))
        let report = try await webView.evaluateJavaScript("""
        JSON.stringify({
          href: location.href,
          injected: document.documentElement.getAttribute("data-injected"),
          chrome: document.documentElement.getAttribute("data-chrome"),
          browser: document.documentElement.getAttribute("data-browser"),
          id: document.documentElement.getAttribute("data-id"),
          touched: document.querySelector("#pw") && document.querySelector("#pw").getAttribute("data-touched")
        })
        """) as? String ?? "nil"
        let sameController = configuration.webExtensionController === controller
        XCTAssertTrue(sameController, "copied configuration lost the extension controller")
        XCTAssertTrue(report.contains(#""injected":"1""#), report)
        XCTAssertTrue(report.contains(#""touched":"1""#), report)
    }

    func testProtonContentScriptReachesPasswordField() async throws {
        let source = URL(filePath: "/Users/macbook/Projects/barc/.build/proton-fixture")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path()))
        let port = 18766
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-proton-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: directory)
        root = directory
        ChromeCompatibility.apply(to: directory)
        let background = directory.appending(path: "background.js")
        var backgroundText = try String(contentsOf: background, encoding: .utf8)
        backgroundText = backgroundText.replacingOccurrences(
            of: "if(void 0===r.frameId||r.frameId>0&&!await e.service.autofill.iframeAutofillEnabled())return!0;",
            with: "if(void 0===r.frameId||r.frameId>0&&!await e.service.autofill.iframeAutofillEnabled()){globalThis.__barcWhy=\"frame \"+r.frameId;return!0;}"
        )
        backgroundText = backgroundText.replacingOccurrences(
            of: "!a.Passkeys)return!0;return await e6(",
            with: "!a.Passkeys){globalThis.__barcWhy=\"features off\";return!0;}globalThis.__barcWhy=\"inject\";try{await (globalThis.chrome||globalThis.browser).scripting.executeScript({target:{tabId:t,frameIds:[i]},files:[\"client.js\"]});globalThis.__barcWhy+=\" client-ok\";await (globalThis.chrome||globalThis.browser).scripting.executeScript({target:{tabId:t,frameIds:[i]},world:\"MAIN\",files:[\"elements.js\"]});await (globalThis.chrome||globalThis.browser).scripting.executeScript({target:{tabId:t,frameIds:[i]},world:\"MAIN\",func:(hash)=>{window.registerPassElements(hash,true);const name=\"protonpass-root-\"+hash;document.documentElement.dataset.elements=String(!!customElements.get(name));},args:[\"abcd\"]});globalThis.__barcWhy+=\" elements-ok\";}catch(err){globalThis.__barcWhy+=\" fail-\"+err;}return await e6("
        )
        backgroundText = """
        globalThis.__barcBoot = "scripting=" + typeof (chrome.scripting && chrome.scripting.executeScript);
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
          if (message && message.barcSender) {
            sendResponse({ frameId: sender && sender.frameId, tab: sender && sender.tab && sender.tab.id, boot: globalThis.__barcBoot, inj: globalThis.__barcInj || null, why: globalThis.__barcWhy || null });
            return true;
          }
        });
        (() => {
          const note = (text) => { globalThis.__barcInj = (globalThis.__barcInj || "") + text; };
          const seen = new Set();
          for (const root of [globalThis.chrome, globalThis.browser]) {
            const scripting = root && root.scripting;
            if (!scripting || seen.has(scripting) || typeof scripting.executeScript !== "function") continue;
            seen.add(scripting);
            const original = scripting.executeScript.bind(scripting);
            scripting.executeScript = (details) => original(details).then(
              (value) => { note("OK " + JSON.stringify(details && details.files) + "; "); return value; },
              (error) => { note("ERR " + (error && error.message || error) + "; "); throw error; }
            );
          }
          if (!globalThis.__barcInj) note(seen.size ? "" : "unwrapped; ");
        })();

        """ + backgroundText
        try backgroundText.write(to: background, atomically: true, encoding: .utf8)
        let client = directory.appending(path: "client.js")
        var clientText = try String(contentsOf: client, encoding: .utf8)
        clientText = """
        document.documentElement.setAttribute("data-client", "start");
        addEventListener("error", (event) => document.documentElement.setAttribute("data-client", String(event.message)));

        """ + clientText
        if let range = clientText.range(of: ".init())().catch(ee)", options: .backwards) {
            clientText.replaceSubrange(range, with: ".init())().catch((e)=>{document.documentElement.setAttribute(\"data-client\", String(e&&(e.message||e)));})")
        }
        clientText = clientText.replacingOccurrences(
            of: "}catch{A.destroy()}},350,{leading:!1,trailing:!0}",
            with: "}catch(err){document.documentElement.setAttribute(\"data-client\", String(err&&(err.message||err)));A.destroy()}},350,{leading:!1,trailing:!0}"
        )
        try clientText.write(to: client, atomically: true, encoding: .utf8)
        let content = directory.appending(path: "orchestrator.js")
        var sourceText = try String(contentsOf: content, encoding: .utf8)
        let recorder = """
        document.documentElement.setAttribute("data-cs-ran", "1");
          chrome.runtime.onMessage.addListener((message) => {
            if (message && message.barcInj) document.documentElement.setAttribute("data-inj", message.barcInj);
          });
        (() => {
          const runtime = (globalThis.browser || globalThis.chrome).runtime;
          const original = runtime.sendMessage.bind(runtime);
          runtime.sendMessage = function(...args) {
            let result;
            try { result = original(...args); }
            catch (error) {
              document.documentElement.setAttribute("data-msg", "THROW " + error);
              throw error;
            }
            const record = (value) => {
              const request = JSON.stringify(args[0]).slice(0, 120);
              const previous = document.documentElement.getAttribute("data-msg") || "";
              document.documentElement.setAttribute("data-msg", (previous + " | " + request + " => " + JSON.stringify(value)).slice(-900));
            };
            Promise.resolve(result).then(record, (error) => record("ERR " + (error && error.message || error)));
            return result;
          };
        })();
        setTimeout(() => {
          chrome.runtime.sendMessage({ barcSender: 1 }).then((value) => {
            document.documentElement.setAttribute("data-sender", JSON.stringify(value));
          });
        }, 2500);

        """
        if let end = sourceText.range(of: "})();\n") {
            sourceText.insert(contentsOf: recorder, at: end.upperBound)
        } else {
            sourceText = recorder + sourceText
        }
        try sourceText.write(to: content, atomically: true, encoding: .utf8)
        let page = directory.appending(path: "login.html")
        try """
        <style>input{width:240px;height:32px;display:block;margin:12px}</style>
        <form>
          <input type="email" name="username" autocomplete="username">
          <input id="pw" type="password" name="password" autocomplete="current-password">
        </form>
        """.write(to: page, atomically: true, encoding: .utf8)

        let http = Process()
        http.executableURL = URL(filePath: "/usr/bin/python3")
        http.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        http.currentDirectoryURL = directory
        try http.run()
        server = http

        let shared = WKWebViewConfiguration()
        shared.websiteDataStore = .default()
        let controllerConfiguration = WKWebExtensionController.Configuration(identifier: UUID(uuidString: "5C2A7F0E-8B1D-4C39-9E62-0B7A1D3F4E21")!)
        controllerConfiguration.webViewConfiguration = shared
        let controller = WKWebExtensionController(configuration: controllerConfiguration)
        shared.webExtensionController = controller
        let delegate = ProbeDelegate()
        controller.delegate = delegate

        let ext = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = "ghmbeldphafepmbegfdlkpapadhbakde"
        if let base = URL(string: "webkit-extension://ghmbeldphafepmbegfdlkpapadhbakde/") { context.baseURL = base }
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        try await context.loadBackgroundContent()

        let configuration = shared.copy() as! WKWebViewConfiguration
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = ProbeTab(webView: webView)
        delegate.tab = tab
        controller.didOpenWindow(delegate)
        controller.didOpenTab(tab)

        let loaded = expectation(description: "login")
        let watcher = ProbeNavigation(done: loaded)
        webView.navigationDelegate = watcher
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/login.html")!))
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertNil(watcher.error, watcher.error ?? "")
        try await Task.sleep(for: .seconds(4))

        let report = try await webView.evaluateJavaScript("""
        JSON.stringify({
          ran: document.documentElement.getAttribute("data-cs-ran"),
          msg: document.documentElement.getAttribute("data-msg"),
          roles: document.querySelectorAll("[data-protonpass-role]").length,
          inj: document.documentElement.getAttribute("data-inj"),
          sender: document.documentElement.getAttribute("data-sender"),
          client: document.documentElement.getAttribute("data-client"),
          elements: document.documentElement.dataset.elements || null,
          visibility: document.visibilityState,
          box: document.querySelector("#pw").getBoundingClientRect().width
        })
        """) as? String ?? "nil"
        XCTAssertEqual(report.contains(#""visibility":"hidden""#), report.contains(#""client":"start""#))
        XCTAssertTrue(report.contains("elements-ok"), report)
    }

    func testMainWorldExecuteScriptMarksField() async throws {
        let port = 18767
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-scripting-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
        try """
        {"manifest_version":3,"name":"Script Probe","version":"1.0","description":"probe","permissions":["scripting"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"background.js"},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}]}
        """.write(to: directory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
          const target = { tabId: sender.tab && sender.tab.id, allFrames: false, frameIds: [sender.frameId || 0] };
          chrome.scripting.executeScript({ target, files: ["mark.js"] })
            .then(() => sendResponse({ ok: true, tab: target.tabId, frame: sender.frameId }))
            .catch((error) => sendResponse({ ok: false, tab: target.tabId, frame: sender.frameId, error: String(error && error.message || error) }));
          return true;
        });
        """.write(to: directory.appending(path: "background.js"), atomically: true, encoding: .utf8)
        try """
        document.documentElement.dataset.main = "yes";
        const field = document.querySelector("input");
        if (field) field.dataset.touched = "yes";
        """.write(to: directory.appending(path: "mark.js"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.sendMessage({ ping: 1 }).then((result) => {
          document.documentElement.dataset.result = JSON.stringify(result);
        }).catch((error) => {
          document.documentElement.dataset.result = "ERR " + error;
        });
        """.write(to: directory.appending(path: "content.js"), atomically: true, encoding: .utf8)
        try #"<input id="pw" type="password" style="width:240px;height:32px">"#.write(to: directory.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let http = Process()
        http.executableURL = URL(filePath: "/usr/bin/python3")
        http.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        http.currentDirectoryURL = directory
        try http.run()
        server = http

        let shared = WKWebViewConfiguration()
        let controllerConfiguration = WKWebExtensionController.Configuration(identifier: UUID())
        controllerConfiguration.webViewConfiguration = shared
        let controller = WKWebExtensionController(configuration: controllerConfiguration)
        shared.webExtensionController = controller
        let delegate = ProbeDelegate()
        controller.delegate = delegate
        let ext = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: ext)
        for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try controller.load(context)
        try await context.loadBackgroundContent()

        let configuration = shared.copy() as! WKWebViewConfiguration
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        let tab = ProbeTab(webView: webView)
        delegate.tab = tab
        controller.didOpenWindow(delegate)
        controller.didOpenTab(tab)

        let loaded = expectation(description: "form")
        let watcher = ProbeNavigation(done: loaded)
        webView.navigationDelegate = watcher
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/index.html")!))
        await fulfillment(of: [loaded], timeout: 15)
        try await Task.sleep(for: .seconds(2))
        let report = try await webView.evaluateJavaScript("""
        JSON.stringify({
          result: document.documentElement.dataset.result || null,
          main: document.documentElement.dataset.main || null,
          touched: document.querySelector("#pw").dataset.touched || null
        })
        """) as? String ?? "nil"
        XCTAssertTrue(report.contains(#""touched":"yes""#), report)
    }

    func testInjectedScriptsCanUseRequestIdleCallback() async throws {
        let port = 18768
        let directory = FileManager.default.temporaryDirectory.appending(path: "barc-idle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
        try """
        {"manifest_version":3,"name":"Idle Probe","version":"1.0","description":"probe","permissions":["scripting"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"background.js"},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}]}
        """.write(to: directory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
          chrome.scripting.executeScript({ target: { tabId: sender.tab.id }, files: ["injected.js"] })
            .then(() => sendResponse(true), () => sendResponse(false));
          return true;
        });
        """.write(to: directory.appending(path: "background.js"), atomically: true, encoding: .utf8)
        try """
        requestIdleCallback(() => { document.documentElement.dataset.content = "idle"; });
        chrome.runtime.sendMessage({ inject: 1 });
        """.write(to: directory.appending(path: "content.js"), atomically: true, encoding: .utf8)
        try """
        const handle = requestIdleCallback(() => { document.documentElement.dataset.cancelled = "no"; });
        cancelIdleCallback(handle);
        requestIdleCallback((deadline) => { document.documentElement.dataset.injected = typeof deadline.timeRemaining(); }, { timeout: 100 });
        """.write(to: directory.appending(path: "injected.js"), atomically: true, encoding: .utf8)
        try "<p>idle</p>".write(to: directory.appending(path: "index.html"), atomically: true, encoding: .utf8)
        ChromeCompatibility.apply(to: directory)

        let http = Process()
        http.executableURL = URL(filePath: "/usr/bin/python3")
        http.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        http.currentDirectoryURL = directory
        try http.run()
        server = http

        let shared = WKWebViewConfiguration()
        let controllerConfiguration = WKWebExtensionController.Configuration(identifier: UUID())
        controllerConfiguration.webViewConfiguration = shared
        let controller = WKWebExtensionController(configuration: controllerConfiguration)
        shared.webExtensionController = controller
        let delegate = ProbeDelegate()
        controller.delegate = delegate
        let ext = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: ext)
        for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        try controller.load(context)
        try await context.loadBackgroundContent()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: shared.copy() as! WKWebViewConfiguration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        let tab = ProbeTab(webView: webView)
        delegate.tab = tab
        controller.didOpenWindow(delegate)
        controller.didOpenTab(tab)

        let loaded = expectation(description: "page")
        let watcher = ProbeNavigation(done: loaded)
        webView.navigationDelegate = watcher
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/index.html")!))
        await fulfillment(of: [loaded], timeout: 15)
        try await Task.sleep(for: .seconds(2))
        let report = try await webView.evaluateJavaScript("JSON.stringify(document.documentElement.dataset)") as? String ?? "nil"
        XCTAssertEqual(report, #"{"content":"idle","injected":"number"}"#)
    }
}

private final class ProbeNavigation: NSObject, WKNavigationDelegate {
    let done: XCTestExpectation
    init(done: XCTestExpectation) { self.done = done }
    var error: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
        done.fulfill()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
        done.fulfill()
    }
}

private final class ProbeTab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    init(webView: WKWebView) { self.webView = webView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { nil }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { nil }
    func setParentTab(_ parent: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { completionHandler(nil) }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { completionHandler(nil) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { completionHandler(nil) }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func title(for context: WKWebExtensionContext) -> String? { "probe" }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { completionHandler(nil) }
}

private final class ProbeDelegate: NSObject, WKWebExtensionControllerDelegate, WKWebExtensionWindow {
    var tab: ProbeTab?
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [self] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tab.map { [$0] } ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) { completionHandler(nil) }
}

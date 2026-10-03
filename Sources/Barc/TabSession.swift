import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class TabSession: NSObject {
    let id: UUID
    let dataStore: WKWebsiteDataStore
    private(set) var webView: WKWebView?
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var isSecure = true
    var currentURL: URL?

    @ObservationIgnored weak var browser: BrowserStore?
    @ObservationIgnored var onUpdate: ((URL?, String) -> Void)?
    @ObservationIgnored var onOpenTab: ((URL, Bool) -> Void)?
    @ObservationIgnored var onCreatePopup: ((WKWebViewConfiguration) -> WKWebView?)?
    @ObservationIgnored var onRequestClose: (() -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var savedState: Any?
    @ObservationIgnored private var pendingURL: URL?

    // Slack blocks Safari versions below 26. Report the installed Safari version.
    // WebKit still freezes the Safari token at 605.1.15.
    static let userAgentSuffix: String = {
        let version = installedSafariVersion() ?? fallbackSafariVersion()
        return "Version/\(version) Safari/605.1.15"
    }()

    private static func installedSafariVersion() -> String? {
        let candidates = [
            "/Applications/Safari.app",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
        ]
        for path in candidates {
            guard let raw = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { continue }
            let parts = raw.split(separator: ".")
            guard let major = parts.first, let majorNumber = Int(major), majorNumber > 0 else { continue }
            let minor = parts.count > 1 ? parts[1] : "0"
            return "\(major).\(minor)"
        }
        return nil
    }

    private static func fallbackSafariVersion() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion >= 26 { return "\(os.majorVersion).\(os.minorVersion)" }
        return "26.0"
    }

    init(id: UUID, url: URL?, dataStore: WKWebsiteDataStore) {
        self.id = id
        self.dataStore = dataStore
        self.pendingURL = url
        self.currentURL = url
    }

    var isLive: Bool { webView != nil }

    func activate() {
        guard webView == nil else { return }
        attach(WKWebView(frame: .zero, configuration: ExtensionManager.shared.configuration(for: pendingURL, dataStore: dataStore)))
        if let state = savedState {
            webView?.interactionState = state
            savedState = nil
        } else if let url = pendingURL {
            webView?.load(URLRequest(url: url))
        }
        ExtensionManager.shared.tabOpened(self)
    }

    func adopt(_ popup: WKWebView) {
        attach(popup)
        ExtensionManager.shared.tabOpened(self)
    }

    private func attach(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.isInspectable = true
        view.underPageBackgroundColor = .white
        webView = view
        observe(view)
    }

    func unload() {
        guard let webView else { return }
        savedState = webView.interactionState
        pendingURL = webView.url ?? pendingURL
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
        progress = 0
    }

    func load(_ url: URL) {
        savedState = nil
        pendingURL = url
        currentURL = url
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            activate()
        }
    }

    func resetHistory(to url: URL) {
        unload()
        savedState = nil
        pendingURL = url
        currentURL = url
    }

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = view.isLoading
                    ExtensionManager.shared.tabChanged(self, [.loading])
                }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isSecure = view.hasOnlySecureContent }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.publish(view) }
            },
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.publish(view) }
            },
        ]
    }

    private func publish(_ view: WKWebView) {
        guard let url = view.url else { return }
        currentURL = url
        pendingURL = url
        onUpdate?(url, view.title ?? "")
        ExtensionManager.shared.tabChanged(self, [.URL, .title])
    }

    private func fetchFavicon(_ view: WKWebView) {
        guard let pageURL = view.url, let host = pageURL.host() else { return }
        let script = """
        Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]'))
          .map(l => [l.href, l.getAttribute('sizes') || '', l.rel])
        """
        view.evaluateJavaScript(script) { result, _ in
            let links = (result as? [[String]]) ?? []
            MainActor.assumeIsolated {
                FaviconStore.shared.update(host: host, pageURL: pageURL, links: links)
            }
        }
    }
}

extension TabSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        if action.navigationType == .linkActivated, let url = action.request.url {
            let flags = action.modifierFlags
            if flags.contains(.command) || action.buttonNumber == 4 {
                onOpenTab?(url, !flags.contains(.shift))
                return (.cancel, preferences)
            }
        }
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "file", "data", "blob", "javascript", "webkit-extension"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadCenter.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadCenter.shared.track(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fetchFavicon(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension TabSession: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let popup = onCreatePopup?(configuration) {
            return popup
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        onRequestClose?()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    @discardableResult
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = webView?.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

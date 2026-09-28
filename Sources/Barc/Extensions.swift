import AppKit
import Observation
import SwiftUI
import WebKit

struct InstalledExtension: Codable, Identifiable, Equatable {
    var id: String
    var enabled = true
    var pinned = false
    var webStoreID: String?

    init(id: String, enabled: Bool = true, pinned: Bool = false, webStoreID: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.pinned = pinned
        self.webStoreID = webStoreID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        webStoreID = try container.decodeIfPresent(String.self, forKey: .webStoreID)
    }
}

enum ExtensionError: LocalizedError {
    case invalidInput
    case downloadFailed(Int)
    case badPackage
    case noManifest

    var errorDescription: String? {
        switch self {
        case .invalidInput: "That doesn't look like a Chrome Web Store link or extension ID."
        case .downloadFailed(let code): "The Chrome Web Store download failed (HTTP \(code))."
        case .badPackage: "The extension package couldn't be read."
        case .noManifest: "No manifest.json was found in the extension."
        }
    }
}

enum ChromeCompatibility {
    static let scriptName = "barc-chrome-compat.js"
    static let backgroundName = "barc-background.js"
    static let flagName = "barc-background-flag.js"
    static let version = 2
    static let stampName = ".barc-compat"
    static let idleMarker = "/* barc-idle */"
    static let idleShim = idleMarker + #"if(typeof globalThis.requestIdleCallback!=="function"){globalThis.requestIdleCallback=function(c,o){var s=Date.now();return setTimeout(function(){c({didTimeout:false,timeRemaining:function(){return Math.max(0,50-(Date.now()-s))}})},1)};globalThis.cancelIdleCallback=function(i){clearTimeout(i)}}"#

    static let script = """
    // Added by Barc: fills in Chrome-only extension APIs that WebKit doesn't provide, so extensions don't crash on startup.
    (() => {
      const event = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; } });
      const resolved = (value) => () => Promise.resolve(value);
      const keep = (globalThis.__barcKeep ||= []);
      const fill = (object, values) => {
        if (!object) return;
        keep.push(object);
        for (const [key, value] of Object.entries(values)) {
          if (object[key] !== undefined) continue;
          try { object[key] = value; } catch (_) {}
        }
      };
      const patch = (root) => {
        if (!root) return;
        fill(root.runtime, {
          onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
          onConnectExternal: event(), onMessageExternal: event(),
          requestUpdateCheck: resolved(["no_update", {}]), getContexts: resolved([]), setUninstallURL: resolved(undefined),
        });
        fill(root.action, { openPopup: resolved(undefined), setBadgeTextColor: resolved(undefined), getUserSettings: resolved({ isOnToolbar: true }) });
        fill(root.storage, { managed: { get: resolved({}), getBytesInUse: resolved(0), onChanged: event() } });
        fill(root, {
          offscreen: { Reason: new Proxy({}, { get: (_, key) => String(key) }), createDocument: resolved(undefined), closeDocument: resolved(undefined), hasDocument: resolved(false) },
          sidePanel: { setPanelBehavior: resolved(undefined), setOptions: resolved(undefined), open: resolved(undefined), getOptions: resolved({}) },
          privacy: { network: {}, services: {}, websites: {} },
          tabGroups: { query: resolved([]), update: resolved(undefined), onUpdated: event(), onRemoved: event(), onCreated: event(), TAB_GROUP_ID_NONE: -1 },
          idle: { queryState: resolved("active"), setDetectionInterval() {}, onStateChanged: event() },
          power: { requestKeepAwake() {}, releaseKeepAwake() {} },
          fontSettings: { getFontList: resolved([]) },
        });
      };
      patch(globalThis.chrome);
      if (globalThis.browser !== globalThis.chrome) patch(globalThis.browser);
      // Some extensions swap these globals for locked-down proxies, which cuts off WebKit's own message delivery.
      for (const name of ["chrome", "browser"]) {
        const value = globalThis[name];
        if (!value) continue;
        try { Object.defineProperty(globalThis, name, { get: () => value, set() {}, configurable: false, enumerable: true }); } catch (_) {}
      }

      // Extension popups often copy the viewport size into their layout. WebKit's popup view
      // starts smaller than the page's declared size, so that copy locks the panel shut.
      // Report the declared size until the view has actually grown to it.
      if (typeof document !== "undefined" && document.documentElement) {
        const holdPopupViewport = () => {
          const root = document.documentElement;
          const px = (value) => {
            const n = parseFloat(value);
            return Number.isFinite(n) && n > 0 ? n : 0;
          };
          const rootStyle = getComputedStyle(root);
          const bodyStyle = document.body ? getComputedStyle(document.body) : null;
          const wantW = Math.max(px(rootStyle.width), px(rootStyle.getPropertyValue("--popup-width")), bodyStyle ? px(bodyStyle.width) : 0);
          const wantH = Math.max(px(rootStyle.height), px(rootStyle.getPropertyValue("--popup-height")), bodyStyle ? px(bodyStyle.height) : 0);
          if (wantW < 80 && wantH < 80) return;
          const elementWidth = Object.getOwnPropertyDescriptor(Element.prototype, "clientWidth");
          const elementHeight = Object.getOwnPropertyDescriptor(Element.prototype, "clientHeight");
          const windowWidth = Object.getOwnPropertyDescriptor(Window.prototype, "innerWidth");
          const windowHeight = Object.getOwnPropertyDescriptor(Window.prototype, "innerHeight");
          if (!elementWidth || !elementHeight || !windowWidth || !windowHeight) return;
          let released = false;
          const release = () => {
            if (released) return;
            released = true;
            try { delete root.clientWidth; delete root.clientHeight; delete window.innerWidth; delete window.innerHeight; } catch (_) {}
          };
          const realW = () => elementWidth.get.call(root);
          const realH = () => elementHeight.get.call(root);
          const caughtUp = () => (wantW < 80 || realW() + 1 >= wantW) && (wantH < 80 || realH() + 1 >= wantH);
          if (caughtUp()) return;
          const override = (object, name, want, real) => {
            Object.defineProperty(object, name, {
              configurable: true,
              get() {
                const value = real();
                if (caughtUp()) queueMicrotask(release);
                return Math.max(value, want);
              },
            });
          };
          if (wantW >= 80) {
            override(root, "clientWidth", wantW, realW);
            override(window, "innerWidth", wantW, () => windowWidth.get.call(window));
          }
          if (wantH >= 80) {
            override(root, "clientHeight", wantH, realH);
            override(window, "innerHeight", wantH, () => windowHeight.get.call(window));
          }
          setTimeout(release, 4000);
        };
        if (document.readyState === "loading") {
          document.addEventListener("readystatechange", () => {
            if (document.readyState === "interactive") holdPopupViewport();
          }, { once: true });
        } else {
          holdPopupViewport();
        }
      }

      const runtime = (globalThis.chrome || globalThis.browser || {}).runtime;
      // WebKit omits sender.frameId. Proton treats that as "not a frame" and never attaches to inputs.
      const seenMessages = new Set();
      for (const root of [globalThis.chrome, globalThis.browser]) {
        const messaging = root && root.runtime && root.runtime.onMessage;
        if (!messaging || seenMessages.has(messaging) || typeof messaging.addListener !== "function") continue;
        seenMessages.add(messaging);
        const nativeAdd = messaging.addListener.bind(messaging);
        try {
          messaging.addListener = (listener) => nativeAdd((message, sender, sendResponse) => {
            const next = sender ? Object.assign({}, sender) : {};
            if (next.frameId == null) next.frameId = 0;
            return listener(message, next, sendResponse);
          });
        } catch (_) {}
      }
      const installed = runtime && runtime.onInstalled;
      if (installed) keep.push(installed);
      if (!globalThis.__barcBackground || !installed || typeof indexedDB === "undefined") return;
      const listeners = [];
      let nativeFired = false;
      const nativeAdd = installed.addListener.bind(installed);
      nativeAdd(() => { nativeFired = true; });
      try {
        installed.addListener = (fn) => { listeners.push(fn); nativeAdd(fn); };
      } catch (_) { return; }
      const version = runtime.getManifest().version;
      const request = indexedDB.open("barc-compat", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("state");
      request.onsuccess = () => {
        const db = request.result;
        const read = db.transaction("state").objectStore("state").get("version");
        read.onsuccess = () => {
          const previous = read.result;
          if (previous === version) return;
          setTimeout(() => {
            db.transaction("state", "readwrite").objectStore("state").put(version, "version");
            if (nativeFired) return;
            const details = previous ? { reason: "update", previousVersion: previous } : { reason: "install" };
            for (const fn of listeners) { try { fn(details); } catch (error) { console.error(error); } }
          }, 1500);
        };
      };
    })();
    """

    static func apply(to root: URL) {
        let fm = FileManager.default
        let manifestURL = root.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        try? script.write(to: root.appending(path: scriptName), atomically: true, encoding: .utf8)
        let stamp = root.appending(path: stampName)
        if (try? String(contentsOf: stamp, encoding: .utf8)) != String(version) {
            addIdleShim(in: root)
            try? String(version).write(to: stamp, atomically: true, encoding: .utf8)
        }
        patchContentScripts(in: root, manifest: manifest)

        try? "self.__barcBackground = true;\n".write(to: root.appending(path: flagName), atomically: true, encoding: .utf8)
        if var background = manifest["background"] as? [String: Any] {
            let wrapperURL = root.appending(path: backgroundName)
            let existingWrapper = (try? String(contentsOf: wrapperURL, encoding: .utf8)) ?? ""
            if let worker = background["service_worker"] as? String, worker != backgroundName || !existingWrapper.contains(flagName) {
                let original = worker == backgroundName
                    ? existingWrapper.components(separatedBy: "\"").filter { $0.hasSuffix(".js") && $0 != scriptName && $0 != flagName && $0 != "./\(scriptName)" && $0 != "./\(flagName)" }.last.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 } ?? "background.js"
                    : (worker.hasPrefix("/") ? String(worker.dropFirst()) : worker)
                let wrapper = background["type"] as? String == "module"
                    ? "import \"./\(flagName)\";\nimport \"./\(scriptName)\";\nimport \"./\(original)\";\n"
                    : "importScripts(\"\(flagName)\", \"\(scriptName)\", \"\(original)\");\n"
                try? wrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
                background["service_worker"] = backgroundName
            } else if var scripts = background["scripts"] as? [String], scripts.first != flagName {
                scripts.removeAll { $0 == scriptName || $0 == flagName }
                scripts.insert(contentsOf: [flagName, scriptName], at: 0)
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }
        if let patched = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? patched.write(to: manifestURL, options: .atomic)
        }

        let tag = "<script src=\"/\(scriptName)\"></script>"
        let pages = fm.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "html" } ?? []
        for page in pages {
            guard var html = try? String(contentsOf: page, encoding: .utf8), !html.contains(tag) else { continue }
            if let head = html.range(of: "<head(\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: page, atomically: true, encoding: .utf8)
        }
    }

    // Content scripts check `chrome.runtime.id` and then replace `chrome` with a proxy.
    // WebKit often only provides `browser`, and the proxy stops messages from reaching the background.
    private static let contentScriptPreamble = """
    /* barc-content-shim */
    (() => {
      if (!globalThis.chrome && globalThis.browser) globalThis.chrome = globalThis.browser;
      if (!globalThis.browser && globalThis.chrome) globalThis.browser = globalThis.chrome;
      const seen = new Set();
      for (const root of [globalThis.chrome, globalThis.browser]) {
        const runtime = root && root.runtime;
        if (!runtime || seen.has(runtime) || typeof runtime.sendMessage !== "function") continue;
        seen.add(runtime);
        const original = runtime.sendMessage.bind(runtime);
        // Proton calls sendMessage(extensionId, message). WebKit only delivers the one-argument form.
        runtime.sendMessage = function(first, ...rest) {
          if (typeof first === "string" && first === runtime.id) return original(...rest);
          return original(first, ...rest);
        };
      }
      for (const name of ["chrome", "browser"]) {
        const value = globalThis[name];
        if (!value) continue;
        try { Object.defineProperty(globalThis, name, { get: () => value, set() {}, configurable: false, enumerable: true }); } catch (_) {}
      }
    })();

    """

    private static func patchContentScripts(in root: URL, manifest: [String: Any]) {
        let entries = manifest["content_scripts"] as? [[String: Any]] ?? []
        for entry in entries {
            for name in entry["js"] as? [String] ?? [] {
                let relative = name.hasPrefix("/") ? String(name.dropFirst()) : name
                let url = root.appending(path: relative)
                guard var source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let start = source.range(of: "/* barc-content-shim */"),
                   let end = source.range(of: "})();", range: start.lowerBound..<source.endIndex) {
                    var removeEnd = end.upperBound
                    while removeEnd < source.endIndex, source[removeEnd] == "\n" { removeEnd = source.index(after: removeEnd) }
                    source.removeSubrange(start.lowerBound..<removeEnd)
                }
                try? (contentScriptPreamble + source).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func addIdleShim(in root: URL) {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { ["js", "mjs"].contains($0.pathExtension.lowercased()) } ?? []
        for file in files {
            guard var source = try? String(contentsOf: file, encoding: .utf8), !source.contains(idleMarker) else { continue }
            var insertAt = source.startIndex
            let body = source.drop { $0.isWhitespace }
            if let directive = ["\"use strict\"", "'use strict'"].first(where: body.hasPrefix) {
                insertAt = source.index(body.startIndex, offsetBy: directive.count)
                source.insert(";", at: insertAt)
                insertAt = source.index(after: insertAt)
            }
            source.insert(contentsOf: idleShim, at: insertAt)
            try? source.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

enum ExtensionPackage {
    static func webStoreID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #/[a-p]{32}/#
        if let url = URL(string: text), let host = url.host(), host.contains("google.com") {
            return url.pathComponents.reversed().compactMap { $0.wholeMatch(of: pattern).map { String($0.output) } }.first
        }
        return text.wholeMatch(of: pattern).map { String($0.output) }
    }

    static func zipData(fromCRX data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x50, 0x4B]) { return data }
        guard bytes.count >= 16, bytes.starts(with: Array("Cr24".utf8)) else { throw ExtensionError.badPackage }
        func uint32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let start: Int
        switch uint32(4) {
        case 3: start = 12 + uint32(8)
        case 2: start = 16 + uint32(8) + uint32(12)
        default: throw ExtensionError.badPackage
        }
        guard start < data.count else { throw ExtensionError.badPackage }
        return data.subdata(in: data.startIndex + start ..< data.endIndex)
    }

    static func unzip(_ zip: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path(), destination.path()]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtensionError.badPackage }
    }

    static func manifestRoot(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appending(path: "manifest.json").path()) { return directory }
        let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if let nested = children.first(where: { fm.fileExists(atPath: $0.appending(path: "manifest.json").path()) }) {
            return nested
        }
        throw ExtensionError.noManifest
    }
}

@MainActor
@Observable
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    let controller: WKWebExtensionController
    let baseConfiguration: WKWebViewConfiguration
    let window = ExtensionWindow()

    private(set) var installed: [InstalledExtension] = []
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private(set) var status: String?
    var revision = 0

    @ObservationIgnored weak var store: BrowserStore?
    @ObservationIgnored var popupAnchors: [String: PopupAnchor] = [:]
    @ObservationIgnored private var popupDismissed: [String: Date] = [:]
    @ObservationIgnored private var popupSizing: Task<Void, Never>?
    @ObservationIgnored private var livePopup: ExtensionPopupHost?

    private var directory: URL {
        let dir = BrowserStore.supportDirectory.appending(path: "Extensions", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var registryURL: URL { directory.appending(path: "extensions.json") }

    override init() {
        // Tab pages have to be created from this same configuration. A fresh configuration that
        // only has the controller assigned does not receive content scripts.
        let shared = WKWebViewConfiguration()
        shared.websiteDataStore = .default()
        shared.applicationNameForUserAgent = TabSession.userAgentSuffix
        shared.preferences.isElementFullscreenEnabled = true
        shared.preferences.javaScriptCanOpenWindowsAutomatically = false
        shared.mediaTypesRequiringUserActionForPlayback = []
        shared.allowsAirPlayForMediaPlayback = true

        let configuration = WKWebExtensionController.Configuration(identifier: UUID(uuidString: "5C2A7F0E-8B1D-4C39-9E62-0B7A1D3F4E21")!)
        configuration.webViewConfiguration = shared
        let extensionController = WKWebExtensionController(configuration: configuration)
        shared.webExtensionController = extensionController
        let world = WKContentWorld.world(name: "BarcWebStore")
        shared.userContentController.addUserScript(WKUserScript(source: WebStoreBridge.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        shared.userContentController.addScriptMessageHandler(WebStoreBridge(), contentWorld: world, name: "barcWebStore")
        controller = extensionController
        baseConfiguration = shared
        super.init()
        controller.delegate = self
    }

    var loadedContexts: [WKWebExtensionContext] {
        installed.filter(\.enabled).compactMap { contexts[$0.id] }
    }

    func configuration(for url: URL?, dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        if let url, url.scheme == "webkit-extension", let context = controller.extensionContext(for: url),
           let configuration = context.webViewConfiguration {
            return configuration
        }
        let configuration = baseConfiguration.copy() as! WKWebViewConfiguration
        configuration.websiteDataStore = dataStore
        return configuration
    }

    func start(store: BrowserStore) {
        self.store = store
        if let data = try? Data(contentsOf: registryURL),
           let list = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            installed = list
        }
        let enabled = installed.filter(\.enabled).map(\.id)
        Task { @MainActor in
            for id in enabled { try? await self.load(id) }
            guard let session = self.store?.selectedSession, session.isLive,
                  let scheme = session.currentURL?.scheme, scheme == "http" || scheme == "https" else { return }
            session.webView?.reload()
        }
    }

    // MARK: - Install

    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    func confirmUninstall(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(displayName(id))” from Barc?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstall(id)
        store?.showToast("Removed \(displayName(id))", symbol: "puzzlepiece.extension")
    }

    func installFromWebStore(_ input: String) async {
        guard let id = ExtensionPackage.webStoreID(from: input) else {
            report(ExtensionError.invalidInput)
            return
        }
        status = "Downloading from Chrome Web Store…"
        defer { status = nil }
        do {
            let chromeVersion = "136.0.0.0"
            let url = URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(chromeVersion)&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")!
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, !data.isEmpty else { throw ExtensionError.downloadFailed(code) }
            status = "Installing…"
            let staging = try stage(zipData: try ExtensionPackage.zipData(fromCRX: data))
            try await finishInstall(staging: staging, id: id, webStoreID: id)
        } catch {
            report(error)
        }
    }

    func installFromFile(_ url: URL) async {
        status = "Installing…"
        defer { status = nil }
        do {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(), isDirectory: &isDirectory)
            let staging: URL
            if isDirectory.boolValue {
                staging = temporaryDirectory()
                try FileManager.default.copyItem(at: url, to: staging)
            } else {
                staging = try stage(zipData: try ExtensionPackage.zipData(fromCRX: try Data(contentsOf: url)))
            }
            try await finishInstall(staging: staging, id: nil, webStoreID: nil)
        } catch {
            report(error)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "barc-ext-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func stage(zipData: Data) throws -> URL {
        let zip = FileManager.default.temporaryDirectory.appending(path: "barc-ext-\(UUID().uuidString).zip")
        try zipData.write(to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        let staging = temporaryDirectory()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try ExtensionPackage.unzip(zip, to: staging)
        return staging
    }

    private func finishInstall(staging: URL, id: String?, webStoreID: String?) async throws {
        defer { try? FileManager.default.removeItem(at: staging) }
        let root = try ExtensionPackage.manifestRoot(in: staging)
        ChromeCompatibility.apply(to: root)
        let preview = try await WKWebExtension(resourceBaseURL: root)
        guard confirmInstall(preview) else { return }

        let identifier = id ?? UUID().uuidString.lowercased()
        let destination = directory.appending(path: identifier, directoryHint: .isDirectory)
        if let existing = contexts[identifier] {
            try? controller.unload(existing)
            contexts[identifier] = nil
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: root, to: destination)

        installed.removeAll { $0.id == identifier }
        installed.append(InstalledExtension(id: identifier, webStoreID: webStoreID))
        saveRegistry()
        try await load(identifier)
        store?.showToast("Added \(preview.displayName ?? "extension")", symbol: "puzzlepiece.extension.fill")
    }

    static func siteAccess(_ ext: WKWebExtension) -> String? {
        let patterns = ext.allRequestedMatchPatterns
        if patterns.contains(where: \.matchesAllHosts) { return "Read and change your data on all websites" }
        let hosts = Array(Set(patterns.compactMap(\.host).filter { !$0.isEmpty })).sorted()
        guard !hosts.isEmpty else { return nil }
        return "Read and change your data on \(hosts.prefix(4).joined(separator: ", "))\(hosts.count > 4 ? " and \(hosts.count - 4) more" : "")"
    }

    static func permissionSummary(_ ext: WKWebExtension) -> [String] {
        let readable: [WKWebExtension.Permission: String] = [
            .tabs: "Read your browsing activity", .webNavigation: "Read your browsing activity",
            .cookies: "Read and change cookies", .scripting: "Run scripts on pages you visit",
            .storage: "Store data locally", .unlimitedStorage: "Store unlimited data locally",
            .contextMenus: "Add items to context menus", .menus: "Add items to context menus",
            .declarativeNetRequest: "Block content on any page", .declarativeNetRequestWithHostAccess: "Block content on any page",
            .webRequest: "Observe network requests", .clipboardWrite: "Modify data you copy and paste",
            .nativeMessaging: "Talk to other apps on your Mac", .alarms: "Run scheduled tasks",
            .activeTab: "Access the current page when you click it",
        ]
        var lines: [String] = []
        for text in ext.requestedPermissions.compactMap({ readable[$0] }).sorted() where !lines.contains(text) {
            lines.append(text)
        }
        return lines
    }

    private func confirmInstall(_ ext: WKWebExtension) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(ext.displayName ?? "Extension")” to Barc?"
        let lines = ([Self.siteAccess(ext)].compactMap { $0 } + Self.permissionSummary(ext)).map { "• \($0)" }
        alert.informativeText = lines.isEmpty ? (ext.displayDescription ?? "") : "It can:\n" + lines.joined(separator: "\n")
        alert.icon = ext.icon(for: CGSize(width: 64, height: 64))
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func load(_ id: String) async throws {
        let folder = directory.appending(path: id, directoryHint: .isDirectory)
        ChromeCompatibility.apply(to: folder)
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = id
        if let base = URL(string: "webkit-extension://\(id.lowercased())/") { context.baseURL = base }
        context.isInspectable = true
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        contexts[id] = context
        Task { try? await context.loadBackgroundContent() }
        revision += 1
    }

    // MARK: - Manage

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        saveRegistry()
        if enabled {
            Task { try? await load(id) }
        } else if let context = contexts[id] {
            try? controller.unload(context)
            contexts[id] = nil
            revision += 1
        }
    }

    func uninstall(_ id: String) {
        if let context = contexts[id] { try? controller.unload(context) }
        contexts[id] = nil
        installed.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory.appending(path: id, directoryHint: .isDirectory))
        saveRegistry()
        revision += 1
    }

    var pinnedContexts: [WKWebExtensionContext] {
        installed.filter { $0.enabled && $0.pinned }.compactMap { contexts[$0.id] }
    }

    func isPinned(_ id: String) -> Bool {
        installed.first { $0.id == id }?.pinned ?? false
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.2)) { installed[index].pinned = pinned }
        saveRegistry()
        store?.showToast(pinned ? "Pinned \(displayName(id)) to the top bar" : "Unpinned \(displayName(id))", symbol: pinned ? "pin.fill" : "pin.slash")
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        store?.newTab(url)
        store?.bringToFront()
    }

    func performAction(_ context: WKWebExtensionContext) {
        context.performAction(for: store?.selectedSession)
    }

    func displayName(_ id: String) -> String {
        contexts[id]?.webExtension.displayName ?? id
    }

    private func saveRegistry() {
        if let data = try? JSONEncoder().encode(installed) { try? data.write(to: registryURL, options: .atomic) }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't add extension"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: - Tab and window events

    func tabOpened(_ tab: TabSession) { controller.didOpenTab(tab) }
    func tabClosed(_ tab: TabSession) { controller.didCloseTab(tab, windowIsClosing: false) }
    func tabActivated(_ tab: TabSession, previous: TabSession?) { controller.didActivateTab(tab, previousActiveTab: previous) }
    func tabChanged(_ tab: TabSession, _ properties: WKWebExtension.TabChangedProperties) { controller.didChangeTabProperties(properties, for: tab) }
    func windowOpened() {
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
    }
}

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let store else { return completionHandler(nil, nil) }
        let id = store.newTab(configuration.url ?? URL(string: "about:blank")!, background: !configuration.shouldBeActive)
        completionHandler(store.session(id), nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        for url in configuration.tabURLs { store?.newTab(url) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { store?.newTab(url) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        completionHandler(ask(extensionContext, "wants additional permissions: \(names)") ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = urls.compactMap { $0.host() }.sorted().joined(separator: ", ")
        completionHandler(ask(extensionContext, "wants to access \(hosts)") ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let text = matchPatterns.contains(where: \.matchesAllHosts) ? "wants to read and change data on all websites" : "wants access to more websites"
        completionHandler(ask(extensionContext, text) ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        revision += 1
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(nil)
        guard let webView = action.popupWebView else { return }
        let id = context.uniqueIdentifier
        if livePopup?.popover.isShown == true {
            livePopup?.popover.performClose(nil)
            return
        }
        if let closed = popupDismissed[id], Date().timeIntervalSince(closed) < 0.4 {
            popupDismissed[id] = nil
            return
        }
        Task { @MainActor in
            let measured = await Self.measurePopup(webView) ?? CGSize(width: 380, height: 480)
            let host = ExtensionPopupHost(action: action, webView: webView, size: self.fittedPopupSize(measured))
            host.popover.appearance = self.store?.isDark == true ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
            host.onClose = { [weak self] in
                self?.popupSizing?.cancel()
                self?.popupDismissed[id] = Date()
                self?.livePopup = nil
            }
            self.livePopup = host
            self.showPopup(host.popover, extensionID: id)
            self.trackPopupSize(host, webView: webView)
        }
    }

    private static let popupMeasureScript = """
    (() => {
      const px = (value) => {
        const n = parseFloat(value);
        return Number.isFinite(n) && n > 0 ? n : 0;
      };
      const root = document.documentElement;
      if (!root) return null;
      let declaredW = 0, declaredH = 0;
      for (const sheet of Array.from(document.styleSheets)) {
        let rules;
        try { rules = sheet.cssRules; } catch (_) { continue; }
        for (const rule of Array.from(rules)) {
          if (!rule.style) continue;
          declaredW = Math.max(declaredW, px(rule.style.getPropertyValue("--popup-width")));
          declaredH = Math.max(declaredH, px(rule.style.getPropertyValue("--popup-height")));
        }
      }
      const currentW = px(getComputedStyle(root).getPropertyValue("--popup-width"));
      const currentH = px(getComputedStyle(root).getPropertyValue("--popup-height"));
      if (declaredW >= 80 && currentW + 1 < declaredW) root.style.setProperty("--popup-width", declaredW + "px");
      if (declaredH >= 80 && currentH + 1 < declaredH) root.style.setProperty("--popup-height", declaredH + "px");
      const rootStyle = getComputedStyle(root);
      const body = document.body;
      const bodyStyle = body ? getComputedStyle(body) : null;
      const width = Math.max(declaredW, px(rootStyle.width), px(rootStyle.getPropertyValue("--popup-width")), bodyStyle ? px(bodyStyle.width) : 0, root.scrollWidth, body ? body.scrollWidth : 0);
      const height = Math.max(declaredH, px(rootStyle.height), px(rootStyle.getPropertyValue("--popup-height")), bodyStyle ? px(bodyStyle.height) : 0, root.scrollHeight, body ? body.scrollHeight : 0);
      return { width, height };
    })()
    """

    private static func measurePopup(_ webView: WKWebView) async -> CGSize? {
        guard let result = try? await webView.evaluateJavaScript(popupMeasureScript) else { return nil }
        let values: [String: Any]
        if let dictionary = result as? [String: Any] {
            values = dictionary
        } else if let dictionary = result as? NSDictionary {
            values = dictionary.reduce(into: [:]) { partial, entry in
                if let key = entry.key as? String { partial[key] = entry.value }
            }
        } else {
            return nil
        }
        func number(_ value: Any?) -> CGFloat? {
            if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
            if let value = value as? Double { return CGFloat(value) }
            if let value = value as? Int { return CGFloat(value) }
            return nil
        }
        guard let width = number(values["width"]), let height = number(values["height"]), width >= 50, height >= 50 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func fittedPopupSize(_ size: CGSize) -> CGSize {
        let screenHeight = store?.window?.screen?.visibleFrame.height ?? 900
        return CGSize(
            width: min(800, max(50, size.width.rounded())),
            height: min(600, screenHeight - 80, max(50, size.height.rounded()))
        )
    }

    private func trackPopupSize(_ host: ExtensionPopupHost, webView: WKWebView) {
        popupSizing?.cancel()
        popupSizing = Task { @MainActor in
            while !Task.isCancelled, host.popover.isShown {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, host.popover.isShown else { return }
                if let size = await Self.measurePopup(webView) {
                    host.update(size: fittedPopupSize(size))
                }
            }
        }
    }

    func registerPopupAnchor(_ key: String, _ view: NSView) {
        popupAnchors[key] = PopupAnchor(view)
    }

    private func showPopup(_ popover: NSPopover, extensionID: String) {
        if let view = popupAnchors[extensionID]?.view ?? popupAnchors[ExtensionPopup.menuAnchor]?.view, view.window != nil {
            let bounds = view.bounds
            let rect = bounds.width < 1 || bounds.height < 1 ? NSRect(x: 0, y: 0, width: 28, height: 28) : bounds
            popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
            return
        }
        guard let content = store?.window?.contentView else { return }
        let rect = NSRect(x: content.bounds.maxX - 36, y: content.bounds.maxY - 8, width: 28, height: 8)
        popover.show(relativeTo: rect, of: content, preferredEdge: .minY)
    }

    private func ask(_ context: WKWebExtensionContext, _ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "“\(context.webExtension.displayName ?? "Extension")” \(text)"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private var store: BrowserStore? { ExtensionManager.shared.store }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let store else { return [] }
        return store.navigableTabs.compactMap { id in
            let session = store.session(id)
            return session.isLive ? session : nil
        }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        store?.selectedSession
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = store?.window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { store?.window?.frame ?? .zero }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { store?.window?.screen?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        store?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }
}

extension TabSession: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionManager.shared.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser?.navigableTabs.firstIndex(of: id) ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? { browser?.record(id)?.displayTitle }

    func url(for context: WKWebExtensionContext) -> URL? { currentURL }

    func isPinned(for context: WKWebExtensionContext) -> Bool { browser?.isPinned(id) ?? false }

    func isSelected(for context: WKWebExtensionContext) -> Bool { browser?.selectedTabID == id }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.select(id)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.close(id)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }
}

final class WebStoreBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let script = #"""
    (() => {
      const host = location.hostname;
      if (host !== "chromewebstore.google.com" && !(host === "chrome.google.com" && location.pathname.startsWith("/webstore"))) return;
      const native = window.webkit.messageHandlers.barcWebStore;
      const currentID = () => (location.pathname.match(/[a-p]{32}/) || [])[0];
      const state = { id: null, installed: false, busy: false };
      const isStoreButton = (b) => /(Add to|Remove from) (Chrome|Barc)|Adding…/.test(b.textContent || "");
      const label = () => state.busy ? "Adding…" : (state.installed ? "Remove from Barc" : "Add to Barc");

      function decorate() {
        const id = currentID();
        if (!id) return;
        if (id !== state.id) { state.id = id; refresh(); }
        for (const button of document.querySelectorAll("button")) {
          if (!button.dataset.barc && !isStoreButton(button)) continue;
          button.dataset.barc = "1";
          if (button.disabled !== state.busy) button.disabled = state.busy;
          button.removeAttribute("aria-disabled");
          const spans = [...button.querySelectorAll("span")].filter(s => /(Add to|Remove from) (Chrome|Barc)|Adding…/.test(s.textContent) && s.children.length === 0);
          const target = spans[0];
          if (target && target.textContent !== label()) target.textContent = label();
        }
        if (document.querySelector("button[data-barc]")) {
          for (const el of document.querySelectorAll("div, span, p")) {
            if (el.children.length !== 0 || !/^Switch to Chrome to install/.test((el.textContent || "").trim())) continue;
            let box = el;
            while (box.parentElement && box.parentElement !== document.body && !box.parentElement.querySelector("button[data-barc]") && (box.parentElement.textContent || "").length < 300) {
              box = box.parentElement;
            }
            if (box.style.display !== "none") box.style.display = "none";
          }
        }
      }

      async function refresh() {
        const id = state.id;
        const reply = await native.postMessage({ type: "status", id });
        if (id === state.id) { state.installed = !!(reply && reply.installed); decorate(); }
      }

      window.addEventListener("click", async (event) => {
        const button = event.target.closest && event.target.closest("button[data-barc]");
        if (!button) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (state.busy || !state.id) return;
        const type = state.installed ? "remove" : "install";
        state.busy = type === "install";
        decorate();
        const reply = await native.postMessage({ type, id: state.id });
        state.busy = false;
        state.installed = !!(reply && reply.installed);
        decorate();
      }, true);

      let queued = false;
      new MutationObserver(() => {
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; decorate(); });
      }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["disabled"] });
      decorate();
    })();
    """#

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let host = message.frameInfo.request.url?.host() ?? ""
            guard host == "chromewebstore.google.com" || host == "chrome.google.com",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  let id = (body["id"] as? String).flatMap(ExtensionPackage.webStoreID(from:)) else {
                return replyHandler(nil, "invalid request")
            }
            let manager = ExtensionManager.shared
            switch type {
            case "install":
                Task { @MainActor in
                    await manager.installFromWebStore(id)
                    replyHandler(["installed": manager.isInstalled(id)], nil)
                }
            case "remove":
                manager.confirmUninstall(id)
                replyHandler(["installed": manager.isInstalled(id)], nil)
            default:
                replyHandler(["installed": manager.isInstalled(id)], nil)
            }
        }
    }
}

final class PopupFrameView: NSView {
    var lockedSize: CGSize

    init(size: CGSize) {
        lockedSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { lockedSize }
}

final class ExtensionPopupHost: NSViewController, NSPopoverDelegate {
    let popover = NSPopover()
    let action: WKWebExtension.Action
    private let canvas: PopupFrameView
    private var finished = false
    var onClose: (() -> Void)?

    init(action: WKWebExtension.Action, webView: WKWebView, size: CGSize) {
        self.action = action
        canvas = PopupFrameView(size: size)
        super.init(nibName: nil, bundle: nil)
        canvas.setContentHuggingPriority(.required, for: .horizontal)
        canvas.setContentHuggingPriority(.required, for: .vertical)
        canvas.setContentCompressionResistancePriority(.required, for: .horizontal)
        canvas.setContentCompressionResistancePriority(.required, for: .vertical)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        webView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        webView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        webView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        canvas.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            webView.topAnchor.constraint(equalTo: canvas.topAnchor),
            webView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        preferredContentSize = size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = self
        popover.contentSize = size
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = canvas
    }

    func update(size: CGSize) {
        guard abs(canvas.lockedSize.width - size.width) >= 4 || abs(canvas.lockedSize.height - size.height) >= 4 else { return }
        canvas.lockedSize = size
        canvas.invalidateIntrinsicContentSize()
        preferredContentSize = size
        popover.contentSize = size
    }

    func popoverDidClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onClose?()
        action.closePopup()
    }
}

final class PopupAnchor {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

enum ExtensionPopup {
    static let menuAnchor = "menu"
}

struct ExtensionPopupAnchor: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let view = PopupPassthroughView()
        ExtensionManager.shared.registerPopupAnchor(key, view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        ExtensionManager.shared.registerPopupAnchor(key, nsView)
    }
}

final class PopupPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct PinnedExtensionButton: View {
    @Environment(BrowserStore.self) private var store
    let context: WKWebExtensionContext
    @State private var hovering = false
    private var manager = ExtensionManager.shared

    init(context: WKWebExtensionContext) {
        self.context = context
    }

    var body: some View {
        let _ = manager.revision
        let action = context.action(for: store.selectedSession)
        let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16))
        let badge = action?.badgeText ?? ""
        let name = context.webExtension.displayName ?? "Extension"
        let id = context.uniqueIdentifier
        Button {
            manager.performAction(context)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 13, minHeight: 11)
                        .background(store.palette.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
                        .offset(x: -1, y: -2)
                }
            }
            .background(.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ExtensionPopupAnchor(key: id))
        .opacity(action?.isEnabled == false ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(action?.label.isEmpty == false ? action!.label : name)
        .contextMenu {
            Text(name)
            Divider()
            Button("Unpin from Top Bar") { manager.setPinned(id, false) }
            if context.optionsPageURL != nil {
                Button("Options") { manager.openOptions(id) }
            }
            Button("Manage Extensions…") { store.openSettings(tab: "extensions") }
            Divider()
            Button("Remove from Barc…") { manager.confirmUninstall(id) }
        }
    }
}

struct ExtensionMenuItems: View {
    @Environment(BrowserStore.self) private var store
    private var manager = ExtensionManager.shared

    var body: some View {
        let _ = manager.revision
        let contexts = manager.loadedContexts
        if !contexts.isEmpty {
            Section("Extensions") {
                ForEach(contexts, id: \.uniqueIdentifier) { context in
                    let action = context.action(for: store.selectedSession)
                    let badge = action?.badgeText ?? ""
                    Button {
                        let manager = manager
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { manager.performAction(context) }
                    } label: {
                        Label {
                            Text((context.webExtension.displayName ?? "Extension") + (badge.isEmpty ? "" : "  (\(badge))"))
                        } icon: {
                            if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? context.webExtension.icon(for: CGSize(width: 16, height: 16)) {
                                Image(nsImage: icon)
                            }
                        }
                    }
                    .disabled(action?.isEnabled == false)
                }
            }
        }
        if !contexts.isEmpty {
            Menu("Pin to Top Bar") {
                ForEach(contexts, id: \.uniqueIdentifier) { context in
                    let id = context.uniqueIdentifier
                    Toggle(context.webExtension.displayName ?? "Extension", isOn: Binding(
                        get: { manager.isPinned(id) },
                        set: { manager.setPinned(id, $0) }
                    ))
                }
            }
        }
        Button("Get Extensions…") { store.newTab(URL(string: "https://chromewebstore.google.com/category/extensions")!) }
        Button("Manage Extensions…") { store.openSettings(tab: "extensions") }
    }
}

struct ExtensionCard: View {
    let item: InstalledExtension
    let onRemove: () -> Void
    @State private var expanded = false
    private var manager = ExtensionManager.shared

    init(item: InstalledExtension, onRemove: @escaping () -> Void) {
        self.item = item
        self.onRemove = onRemove
    }

    var body: some View {
        let context = manager.contexts[item.id]
        let ext = context?.webExtension
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let icon = ext?.icon(for: CGSize(width: 36, height: 36)) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .saturation(item.enabled ? 1 : 0)
                .opacity(item.enabled ? 1 : 0.5)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(manager.displayName(item.id)).font(.system(size: 13, weight: .semibold))
                        if let version = ext?.displayVersion {
                            Text(version).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    if let errors = context?.errors, !errors.isEmpty {
                        Label(errors.first?.localizedDescription ?? "", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                    } else if !item.enabled {
                        Text("Turned off").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let description = ext?.displayDescription {
                        Text(description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { item.enabled }, set: { manager.setEnabled(item.id, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(item.enabled ? "Turn off" : "Turn on")
            }

            HStack(spacing: 6) {
                CardButton(title: item.pinned ? "Pinned" : "Pin", symbol: item.pinned ? "pin.fill" : "pin", active: item.pinned) {
                    manager.setPinned(item.id, !item.pinned)
                }
                .disabled(!item.enabled)
                CardButton(title: "Details", symbol: expanded ? "chevron.up" : "chevron.down", active: expanded) {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                if context?.optionsPageURL != nil {
                    CardButton(title: "Options", symbol: "slider.horizontal.3") { manager.openOptions(item.id) }
                }
                Spacer()
                CardButton(title: "Remove", symbol: "trash", destructive: true, action: onRemove)
            }

            if expanded, let ext {
                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(title: "Site access", value: ExtensionManager.siteAccess(ext) ?? "No website access")
                    let permissions = ExtensionManager.permissionSummary(ext)
                    if !permissions.isEmpty {
                        DetailRow(title: "Permissions", value: permissions.joined(separator: "\n"))
                    }
                    DetailRow(title: "Source", value: item.webStoreID == nil ? "Loaded from disk" : "Chrome Web Store")
                    DetailRow(title: "ID", value: item.id, monospaced: true)
                    if let storeID = item.webStoreID {
                        Button("View in Chrome Web Store") {
                            manager.store?.newTab(URL(string: "https://chromewebstore.google.com/detail/\(storeID)")!)
                            manager.store?.bringToFront()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}

struct CardButton: View {
    let title: String
    let symbol: String
    var active = false
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .foregroundStyle(destructive ? AnyShapeStyle(.red) : (active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .background(.primary.opacity(active ? 0.12 : (hovering ? 0.08 : 0.05)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ExtensionsSettings: View {
    private var manager = ExtensionManager.shared
    @State private var input = ""
    @State private var removing: String?

    var body: some View {
        let _ = manager.revision
        Form {
            Section {
                HStack {
                    TextField("Chrome Web Store link or extension ID", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(install)
                    Button("Add", action: install)
                        .disabled(input.isEmpty || manager.status != nil)
                }
                HStack {
                    Button("Load Unpacked…") { chooseFile() }
                    Spacer()
                    if let status = manager.status {
                        ProgressView().controlSize(.small)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Chrome extensions run on WebKit's native Web Extensions engine. Most Manifest V3 extensions work; a few Chrome-only APIs don't.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installed") {
                if manager.installed.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text("No extensions yet").foregroundStyle(.secondary)
                        Text("Open any extension in the Chrome Web Store and click Add to Barc.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                ForEach(manager.installed) { item in
                    ExtensionCard(item: item) { removing = item.id }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove this extension?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { manager.uninstall(removing) }
            }
        }
    }

    private func install() {
        let text = input
        input = ""
        Task { await manager.installFromWebStore(text) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .init(filenameExtension: "crx") ?? .data, .folder]
        panel.message = "Choose an unpacked extension folder, a .zip, or a .crx file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await manager.installFromFile(url) }
    }
}

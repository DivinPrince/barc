import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: BrowserStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { store?.saveNow() }
    }
}

@main
struct BarcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = BrowserStore()

    var body: some Scene {
        Window("Barc", id: "main") {
            BrowserView()
                .environment(store)
                .onAppear {
                    delegate.store = store
                    ExtensionManager.shared.start(store: store)
                }
                .onOpenURL { store.newTab($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1320, height: 860)
        .commands { BrowserCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct BrowserCommands: Commands {
    let store: BrowserStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.commandBar = .newTab }
                .keyboardShortcut("t")
            Button("Open Location…") { store.commandBar = .currentTab }
                .keyboardShortcut("l")
            Button("Reopen Closed Tab") { store.reopenClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("New Space") { store.beginCreatingSpace() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder") { store.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Close Tab") { store.closeSelected() }
                .keyboardShortcut("w")
        }

        CommandGroup(replacing: .saveItem) {}

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy URL") { store.copyURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Find…") { store.findVisible = true }
                .keyboardShortcut("f")
        }

        CommandGroup(replacing: .sidebar) {
            Button(store.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.snappy(duration: 0.28)) { store.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s")
            Divider()
            Button("Reload Page") { store.reload() }
                .keyboardShortcut("r")
            Button("Actual Size") { store.zoom(nil) }
                .keyboardShortcut("0")
            Button("Zoom In") { store.zoom(0.1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { store.zoom(-0.1) }
                .keyboardShortcut("-")
        }

        CommandMenu("Tabs") {
            Button("Pin / Unpin Tab") { store.selectedTabID.map(store.togglePin) }
                .keyboardShortcut("d")
            Button("Add to / Remove from Favorites") { store.selectedTabID.map(store.toggleFavorite) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Duplicate Tab") { store.selectedTabID.map(store.duplicate) }
            Divider()
            Button("Back") { store.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { store.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Next Tab") { store.selectAdjacent(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { store.selectAdjacent(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab ") { store.selectAdjacent(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Tab ") { store.selectAdjacent(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            ForEach(1..<10) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store.selectIndex(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Divider()
            Button("Clear Today") { store.clearToday() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        CommandMenu("Spaces") {
            Button("Edit Theme…") { store.openThemeEditor(store.currentSpace.id) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Next Space") { store.switchSpace(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { store.switchSpace(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            ForEach(Array(store.library.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                Button(space.name) { store.switchSpace(space.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ExtensionsSettings()
                .frame(width: 560, height: 460)
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
                .tag("extensions")
        }
    }
}

struct GeneralSettings: View {
    @AppStorage("searchEngine") private var searchEngine = SearchEngine.google.rawValue
    @AppStorage("maxLiveTabs") private var maxLiveTabs = 12
    @State private var isDefault = DefaultBrowser.isBarc

    var body: some View {
        Form {
            LabeledContent("Default browser") {
                if isDefault {
                    Label("Barc is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Make Barc Default") {
                        Task {
                            await DefaultBrowser.makeBarc()
                            isDefault = DefaultBrowser.isBarc
                        }
                    }
                }
            }
            Picker("Search engine", selection: $searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.name).tag(engine.rawValue)
                }
            }
            Stepper(value: $maxLiveTabs, in: 3...40) {
                LabeledContent("Tabs kept in memory", value: "\(maxLiveTabs)")
            }
            Text("Older tabs are put to sleep to save memory and wake instantly with their history when you return.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultBrowser.isBarc
        }
    }
}

enum DefaultBrowser {
    static var isBarc: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
            || Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    @MainActor
    static func makeBarc() async {
        let app = Bundle.main.bundleURL
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't make Barc the default browser"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

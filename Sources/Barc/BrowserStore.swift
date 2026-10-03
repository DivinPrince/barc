import AppKit
import Observation
import SwiftUI
import WebKit

final class LibraryBox {
    var value: Library

    init(value: Library) {
        self.value = value
    }
}

enum CommandBarMode: Equatable {
    case newTab
    case currentTab
}

@MainActor
@Observable
final class BrowserStore {
    let library = Library()

    var history: [String: HistoryEntry] = [:]
    var commandBar: CommandBarMode?
    var findVisible = false
    var topBarVisible = false
    var sidebarPeek = false
    var editingFolder: UUID?
    var spaceTransitionEdge: Edge = .trailing
    var themeEditorSpace: UUID?
    var creatingSpace = false
    var creatingLiveFolder = false
    var refreshingFolders: Set<UUID> = []
    var draggingTab: UUID?
    var draggingFolder: UUID?
    var toast: Toast?
    var systemDark = BrowserStore.readSystemDark()

    @ObservationIgnored private var sessions: [UUID: TabSession] = [:]
    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var liveOrder: [UUID] = []
    @ObservationIgnored private var closedStack: [(TabRecord, Destination)] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dragWatch: Timer?
    @ObservationIgnored private var liveRefreshTimer: Timer?
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            updateTrafficLights()
            if oldValue == nil, window != nil { ExtensionManager.shared.windowOpened() }
        }
    }

    var searchEngine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .google
    }

    private var maxLiveTabs: Int {
        let value = UserDefaults.standard.integer(forKey: "maxLiveTabs")
        return value == 0 ? 12 : value
    }

    static let supportDirectory: URL = {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["BARC_DATA_DIR"], !override.isEmpty {
            base = URL(filePath: override)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        let dir = base.appending(path: "Barc", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let libraryURL = supportDirectory.appending(path: "library.json")
    private static let historyURL = supportDirectory.appending(path: "history.json")

    init() {
        load()
        refreshLiveFolders(olderThan: Self.liveRefreshInterval)
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveFolders(olderThan: Self.liveRefreshInterval) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                withAnimation(.easeInOut(duration: 0.35)) { self?.systemDark = BrowserStore.readSystemDark() }
            }
        }
    }

    private static func readSystemDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    // MARK: - Derived state

    var spaceIndex: Int {
        library.spaces.firstIndex { $0.id == library.selectedSpace } ?? 0
    }

    var currentSpace: Space {
        library.spaces[spaceIndex]
    }

    var palette: Palette { currentSpace.theme.palette(systemDark: systemDark) }

    var isDark: Bool { palette.isDark }

    var selectedTabID: UUID? { currentSpace.selectedTab }

    var selectedSession: TabSession? {
        selectedTabID.map(session)
    }

    var selectedRecord: TabRecord? {
        selectedTabID.flatMap { library.tabs[$0] }
    }

    var sidebarVisible: Bool {
        get { library.sidebarVisible }
        set {
            library.sidebarVisible = newValue
            if newValue { sidebarPeek = false }
            updateTrafficLights()
            scheduleSave()
        }
    }

    func record(_ id: UUID) -> TabRecord? { library.tabs[id] }

    func session(_ id: UUID) -> TabSession {
        if let existing = sessions[id] { return existing }
        let session = TabSession(id: id, url: library.tabs[id]?.url, dataStore: dataStore(forTab: id))
        wire(session)
        sessions[id] = session
        return session
    }

    func isLive(_ id: UUID) -> Bool { sessions[id]?.isLive ?? false }

    func space(of id: UUID) -> Space? {
        guard let dest = location(of: id) else { return nil }
        switch dest {
        case .favorites(let space), .pinned(let space), .folder(let space, _), .today(let space):
            return library.spaces.first { $0.id == space }
        }
    }

    private func dataStore(forTab id: UUID) -> WKWebsiteDataStore {
        guard let space = space(of: id) ?? library.spaces[safe: spaceIndex], !space.sharesData else { return .default() }
        if let store = dataStores[space.id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: space.id)
        dataStores[space.id] = store
        return store
    }

    private func refreshDataStore(forTab id: UUID) {
        guard let existing = sessions[id], existing.dataStore !== dataStore(forTab: id) else { return }
        existing.unload()
        sessions[id] = nil
        liveOrder.removeAll { $0 == id }
        if selectedTabID == id, space(of: id)?.id == library.selectedSpace { select(id) }
    }

    func location(of id: UUID) -> Destination? {
        for space in library.spaces {
            if space.favorites.contains(id) { return .favorites(space: space.id) }
            if space.today.contains(id) { return .today(space: space.id) }
            for item in space.pinned {
                switch item {
                case .tab(let tabID) where tabID == id: return .pinned(space: space.id)
                case .folder(let folder) where folder.tabs.contains(id): return .folder(space: space.id, folder: folder.id)
                default: continue
                }
            }
        }
        return nil
    }

    func isPinned(_ id: UUID) -> Bool {
        switch location(of: id) {
        case .today, nil: false
        default: true
        }
    }

    func isFavorite(_ id: UUID) -> Bool {
        if case .favorites? = location(of: id) { true } else { false }
    }

    var navigableTabs: [UUID] {
        var ids = currentSpace.favorites
        for item in currentSpace.pinned {
            switch item {
            case .tab(let id): ids.append(id)
            case .folder(let folder) where folder.isExpanded: ids.append(contentsOf: folder.tabs)
            default: break
            }
        }
        ids.append(contentsOf: currentSpace.today)
        return ids
    }

    var folders: [Folder] {
        currentSpace.pinned.compactMap { if case .folder(let f) = $0, f.live == nil { f } else { nil } }
    }

    // MARK: - Tabs

    func select(_ id: UUID?) {
        guard let id else {
            library.spaces[spaceIndex].selectedTab = nil
            return
        }
        if case .some(let dest) = location(of: id) {
            switch dest {
            case .favorites(let space), .pinned(let space), .folder(let space, _), .today(let space):
                if space != library.selectedSpace { switchSpace(space) }
            }
        }
        let previous = selectedTabID.flatMap { sessions[$0] }
        library.spaces[spaceIndex].selectedTab = id
        library.tabs[id]?.lastActive = Date()
        let session = session(id)
        session.activate()
        if previous !== session { ExtensionManager.shared.tabActivated(session, previous: previous) }
        liveOrder.removeAll { $0 == id }
        liveOrder.insert(id, at: 0)
        evictIfNeeded()
        focusWebView()
        scheduleSave()
    }

    @discardableResult
    func newTab(_ url: URL, background: Bool = false, at destination: Destination? = nil, index: Int = 0) -> UUID {
        let record = TabRecord(url: url, title: url.host() ?? "")
        library.tabs[record.id] = record
        insert(record.id, at: destination ?? .today(space: currentSpace.id), index: index)
        if background {
            session(record.id).activate()
            liveOrder.insert(record.id, at: min(1, liveOrder.count))
            evictIfNeeded()
        } else {
            select(record.id)
        }
        scheduleSave()
        return record.id
    }

    private func adoptPopup(configuration: WKWebViewConfiguration, opener: UUID) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let record = TabRecord(url: nil, title: "")
        library.tabs[record.id] = record
        let dest: Destination = location(of: opener).flatMap { if case .today = $0 { $0 } else { nil } } ?? .today(space: currentSpace.id)
        insert(record.id, at: dest, index: 0)
        let session = TabSession(id: record.id, url: nil, dataStore: configuration.websiteDataStore)
        wire(session)
        session.adopt(webView)
        sessions[record.id] = session
        select(record.id)
        return webView
    }

    func navigate(_ url: URL) {
        guard let id = selectedTabID else {
            newTab(url)
            return
        }
        session(id).load(url)
        focusWebView()
    }

    func close(_ id: UUID) {
        guard let dest = location(of: id) else { return }
        let wasSelected = selectedTabID == id
        let order = navigableTabs
        var liveFolder: UUID?
        if case .folder(_, let folder) = dest, liveFeed(folder) != nil { liveFolder = folder }
        var removes = liveFolder != nil
        if case .today = dest {
            removes = true
            if let record = library.tabs[id] { closedStack.append((record, dest)) }
            if closedStack.count > 30 { closedStack.removeFirst() }
        }
        if removes {
            if let session = sessions[id] { ExtensionManager.shared.tabClosed(session) }
            detach(id)
            library.tabs[id] = nil
            sessions[id]?.unload()
            sessions[id] = nil
            if let liveFolder { forgetLiveTab(id, in: liveFolder) }
        } else {
            sessions[id]?.unload()
        }
        liveOrder.removeAll { $0 == id }
        if wasSelected {
            let pool = order.filter { $0 != id && (isLive($0) || currentSpace.today.contains($0)) }
            let oldIndex = order.firstIndex(of: id) ?? 0
            let next = pool.first { (order.firstIndex(of: $0) ?? 0) > oldIndex } ?? pool.last
            select(next)
        }
        scheduleSave()
    }

    func closeSelected() {
        guard let id = selectedTabID else {
            window?.performClose(nil)
            return
        }
        close(id)
    }

    func reopenClosed() {
        guard let (record, dest) = closedStack.popLast() else { return }
        library.tabs[record.id] = record
        let target: Destination = library.spaces.contains { space in
            if case .today(let s) = dest { return s == space.id }
            return false
        } ? dest : .today(space: currentSpace.id)
        insert(record.id, at: target, index: 0)
        select(record.id)
        showToast("Reopened tab", symbol: "arrow.uturn.backward")
    }

    func duplicate(_ id: UUID) {
        guard let url = library.tabs[id]?.url else { return }
        newTab(url)
        showToast("Duplicated tab", symbol: "plus.square.on.square")
    }

    func clearToday() {
        let count = currentSpace.today.count
        if count > 0 { showToast("Closed \(count) tab\(count == 1 ? "" : "s") · ⇧⌘T to reopen", symbol: "arrow.down") }
        for id in currentSpace.today {
            sessions[id]?.unload()
            sessions[id] = nil
            liveOrder.removeAll { $0 == id }
            if let record = library.tabs[id] { closedStack.append((record, .today(space: currentSpace.id))) }
            library.tabs[id] = nil
        }
        let selectedWasToday = selectedTabID.map { currentSpace.today.contains($0) } ?? false
        library.spaces[spaceIndex].today = []
        if selectedWasToday { select(nil) }
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let dest = location(of: id) else { return }
        switch dest {
        case .today(let space):
            setHome(id)
            move(.tab(id), to: .pinned(space: space), index: Int.max)
            showToast("Pinned", symbol: "pin.fill")
        case .pinned(let space), .folder(let space, _):
            library.tabs[id]?.homeURL = nil
            move(.tab(id), to: .today(space: space), index: 0)
            showToast("Unpinned", symbol: "pin.slash")
        case .favorites(let space):
            library.tabs[id]?.homeURL = nil
            move(.tab(id), to: .today(space: space), index: 0)
            showToast("Removed from Favorites", symbol: "star.slash")
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard let dest = location(of: id) else { return }
        if case .favorites(let space) = dest {
            library.tabs[id]?.homeURL = nil
            move(.tab(id), to: .today(space: space), index: 0)
            showToast("Removed from Favorites", symbol: "star.slash")
        } else {
            setHome(id)
            move(.tab(id), to: .favorites(space: space(of: id)?.id ?? currentSpace.id), index: Int.max)
            showToast("Added to Favorites", symbol: "star.fill")
        }
    }

    func resetToHome(_ id: UUID) {
        guard let home = library.tabs[id]?.homeURL else { return }
        session(id).load(home)
    }

    func selectAdjacent(_ offset: Int) {
        let ids = navigableTabs
        guard !ids.isEmpty else { return }
        guard let current = selectedTabID, let index = ids.firstIndex(of: current) else {
            select(ids.first)
            return
        }
        select(ids[(index + offset + ids.count) % ids.count])
    }

    func selectIndex(_ number: Int) {
        let ids = navigableTabs
        guard !ids.isEmpty else { return }
        select(number >= 9 ? ids.last : ids[safe: number - 1])
    }

    private func evictIfNeeded() {
        let limit = max(3, maxLiveTabs)
        while liveOrder.count > limit, let victim = liveOrder.last {
            liveOrder.removeLast()
            if victim == selectedTabID { continue }
            sessions[victim]?.unload()
        }
    }

    private func wire(_ session: TabSession) {
        let id = session.id
        session.browser = self
        session.onUpdate = { [weak self] url, title in
            self?.recordUpdate(id: id, url: url, title: title)
        }
        session.onOpenTab = { [weak self] url, background in
            guard let self else { return }
            let dest = location(of: id).flatMap { if case .today = $0 { $0 } else { nil } }
            newTab(url, background: background, at: dest)
        }
        session.onCreatePopup = { [weak self] configuration in
            self?.adoptPopup(configuration: configuration, opener: id)
        }
        session.onRequestClose = { [weak self] in
            self?.close(id)
        }
    }

    private func recordUpdate(id: UUID, url: URL?, title: String) {
        guard var record = library.tabs[id] else { return }
        let newTitle = title.isEmpty ? record.title : title
        guard record.url != url || record.title != newTitle else { return }
        record.url = url
        record.title = newTitle
        library.tabs[id] = record
        if let url, let scheme = url.scheme, scheme.hasPrefix("http") {
            let key = url.absoluteString
            var entry = history[key] ?? HistoryEntry(url: url, title: newTitle, visits: 0, lastVisit: Date())
            if entry.title != newTitle, !newTitle.isEmpty { entry.title = newTitle } else { entry.visits += 1 }
            entry.lastVisit = Date()
            history[key] = entry
        }
        scheduleSave()
    }

    // MARK: - Moving

    enum Movable { case tab(UUID), folder(UUID) }

    func handleDrop(_ items: [String], to destination: Destination, index: Int) -> Bool {
        var handled = false
        for (offset, item) in items.enumerated() {
            switch DragPayload.parse(item) {
            case .tab(let id):
                move(.tab(id), to: destination, index: index == Int.max ? index : index + offset)
                handled = true
            case .folder(let id):
                if case .pinned = destination {
                    move(.folder(id), to: destination, index: index)
                    handled = true
                }
            case nil:
                if let url = URL(string: item.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                    newTab(url, background: true, at: destination, index: index)
                    handled = true
                }
            }
        }
        return handled
    }

    func move(_ item: Movable, to destination: Destination, index: Int) {
        withAnimation(.snappy(duration: 0.25)) {
            switch item {
            case .tab(let id):
                guard library.tabs[id] != nil else { return }
                if case .folder(_, let folderID) = destination, liveFeed(folderID) != nil { return }
                let original = location(of: id)
                let adjusted = adjustedIndex(for: id, from: original, to: destination, index: index)
                detach(id)
                insert(id, at: destination, index: adjusted)
                if case .today = destination {
                    library.tabs[id]?.homeURL = nil
                } else if library.tabs[id]?.homeURL == nil {
                    setHome(id)
                }
                refreshDataStore(forTab: id)
            case .folder(let folderID):
                guard case .pinned(let spaceID) = destination,
                      let sIndex = library.spaces.firstIndex(where: { $0.id == spaceID }),
                      let from = library.spaces[sIndex].pinned.firstIndex(where: { $0.id == folderID }) else { return }
                let folder = library.spaces[sIndex].pinned.remove(at: from)
                let target = min(from < index ? index - 1 : index, library.spaces[sIndex].pinned.count)
                library.spaces[sIndex].pinned.insert(folder, at: max(0, target))
            }
        }
        scheduleSave()
    }

    private func adjustedIndex(for id: UUID, from: Destination?, to: Destination, index: Int) -> Int {
        guard from == to, index != Int.max else { return index }
        let list: [UUID]
        switch to {
        case .favorites(let space): list = library.spaces.first { $0.id == space }?.favorites ?? []
        case .today(let space): list = library.spaces.first { $0.id == space }?.today ?? []
        case .folder(let space, let folder):
            list = library.spaces.first { $0.id == space }?.pinned.compactMap {
                if case .folder(let f) = $0, f.id == folder { f.tabs } else { nil }
            }.first ?? []
        case .pinned(let space):
            let pinned = library.spaces.first { $0.id == space }?.pinned ?? []
            if let current = pinned.firstIndex(where: { $0.id == id }), current < index { return index - 1 }
            return index
        }
        if let current = list.firstIndex(of: id), current < index { return index - 1 }
        return index
    }

    private func setHome(_ id: UUID) {
        guard let url = library.tabs[id]?.url else { return }
        library.tabs[id]?.homeURL = url
    }

    private func detach(_ id: UUID) {
        for s in library.spaces.indices {
            library.spaces[s].favorites.removeAll { $0 == id }
            library.spaces[s].today.removeAll { $0 == id }
            library.spaces[s].pinned.removeAll { $0 == .tab(id) }
            for p in library.spaces[s].pinned.indices {
                if case .folder(var folder) = library.spaces[s].pinned[p], folder.tabs.contains(id) {
                    folder.tabs.removeAll { $0 == id }
                    library.spaces[s].pinned[p] = .folder(folder)
                }
            }
        }
    }

    private func insert(_ id: UUID, at destination: Destination, index: Int) {
        func clamp(_ count: Int) -> Int { max(0, min(index, count)) }
        switch destination {
        case .favorites(let space):
            guard let s = library.spaces.firstIndex(where: { $0.id == space }) else { return }
            library.spaces[s].favorites.insert(id, at: clamp(library.spaces[s].favorites.count))
        case .pinned(let space):
            guard let s = library.spaces.firstIndex(where: { $0.id == space }) else { return }
            library.spaces[s].pinned.insert(.tab(id), at: clamp(library.spaces[s].pinned.count))
        case .today(let space):
            guard let s = library.spaces.firstIndex(where: { $0.id == space }) else { return }
            library.spaces[s].today.insert(id, at: clamp(library.spaces[s].today.count))
        case .folder(let space, let folderID):
            guard let s = library.spaces.firstIndex(where: { $0.id == space }),
                  let p = library.spaces[s].pinned.firstIndex(where: { $0.id == folderID }),
                  case .folder(var folder) = library.spaces[s].pinned[p] else { return }
            folder.tabs.insert(id, at: clamp(folder.tabs.count))
            folder.isExpanded = true
            library.spaces[s].pinned[p] = .folder(folder)
        }
    }

    // MARK: - Live reordering

    func beginDrag(tab: UUID? = nil, folder: UUID? = nil) {
        draggingTab = tab
        draggingFolder = folder
        dragWatch?.invalidate()
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons == 0 { self?.endDrag() }
            }
        }
    }

    func endDrag() {
        dragWatch?.invalidate()
        dragWatch = nil
        draggingTab = nil
        draggingFolder = nil
    }

    func ids(in destination: Destination) -> [UUID] {
        switch destination {
        case .favorites(let space):
            return library.spaces.first { $0.id == space }?.favorites ?? []
        case .today(let space):
            return library.spaces.first { $0.id == space }?.today ?? []
        case .pinned(let space):
            return library.spaces.first { $0.id == space }?.pinned.map(\.id) ?? []
        case .folder(let space, let folder):
            return library.spaces.first { $0.id == space }?.pinned.compactMap {
                if case .folder(let f) = $0, f.id == folder { f.tabs } else { nil }
            }.first ?? []
        }
    }

    @discardableResult
    func liveReorder(onto target: UUID, in destination: Destination) -> Bool {
        let list = ids(in: destination)
        guard let targetIndex = list.firstIndex(of: target) else { return false }
        if let tab = draggingTab, tab != target {
            var index = targetIndex
            if location(of: tab) == destination, let from = list.firstIndex(of: tab), from < targetIndex {
                index = targetIndex + 1
            }
            move(.tab(tab), to: destination, index: index)
            return true
        }
        if let folder = draggingFolder, folder != target, case .pinned = destination, let from = list.firstIndex(of: folder) {
            move(.folder(folder), to: destination, index: from < targetIndex ? targetIndex + 1 : targetIndex)
            return true
        }
        return false
    }

    // MARK: - Toasts

    func showToast(_ text: String, symbol: String) {
        let toast = Toast(text: text, symbol: symbol)
        withAnimation(.snappy(duration: 0.25)) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard self?.toast?.id == toast.id else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }

    // MARK: - Folders

    @discardableResult
    func newFolder(with tab: UUID? = nil) -> UUID {
        let folder = Folder(name: "New Folder")
        withAnimation(.snappy(duration: 0.25)) {
            library.spaces[spaceIndex].pinned.insert(.folder(folder), at: 0)
            if let tab {
                detach(tab)
                insert(tab, at: .folder(space: currentSpace.id, folder: folder.id), index: 0)
                if library.tabs[tab]?.homeURL == nil { library.tabs[tab]?.homeURL = library.tabs[tab]?.url }
            }
        }
        editingFolder = folder.id
        scheduleSave()
        return folder.id
    }

    func updateFolder(_ id: UUID, _ change: (inout Folder) -> Void) {
        for s in library.spaces.indices {
            for p in library.spaces[s].pinned.indices {
                if case .folder(var folder) = library.spaces[s].pinned[p], folder.id == id {
                    change(&folder)
                    library.spaces[s].pinned[p] = .folder(folder)
                    scheduleSave()
                    return
                }
            }
        }
    }

    func deleteFolder(_ id: UUID) {
        guard let p = currentSpace.pinned.firstIndex(where: { $0.id == id }),
              case .folder(let folder) = currentSpace.pinned[p] else { return }
        if folder.live != nil { folder.tabs.forEach(close) }
        withAnimation(.snappy(duration: 0.25)) {
            library.spaces[spaceIndex].pinned.remove(at: p)
            if folder.live == nil {
                library.spaces[spaceIndex].pinned.insert(contentsOf: folder.tabs.map { .tab($0) }, at: p)
            }
        }
        scheduleSave()
    }

    // MARK: - Spaces

    func switchSpace(_ id: UUID) {
        guard id != library.selectedSpace, let target = library.spaces.firstIndex(where: { $0.id == id }) else { return }
        spaceTransitionEdge = target > spaceIndex ? .trailing : .leading
        withAnimation(.snappy(duration: 0.3)) {
            library.selectedSpace = id
        }
        if let tab = currentSpace.selectedTab { select(tab) } else { focusWebView() }
        scheduleSave()
    }

    func switchSpace(offset: Int) {
        let index = spaceIndex + offset
        guard library.spaces.indices.contains(index) else { return }
        switchSpace(library.spaces[index].id)
    }

    var suggestedSpace: Space {
        let used = library.spaces.map(\.theme)
        let theme = (ThemePreset.allCases.first { !used.contains($0.theme) } ?? .ocean).theme
        let usedSymbols = library.spaces.map(\.symbol)
        let symbol = Space.symbols.first { !usedSymbols.contains($0) } ?? "sparkles"
        return Space(name: "Space \(library.spaces.count + 1)", symbol: symbol, theme: theme)
    }

    func beginCreatingSpace() {
        commandBar = nil
        themeEditorSpace = nil
        creatingSpace = true
    }

    @discardableResult
    func addSpace(_ draft: Space? = nil) -> UUID {
        var space = draft ?? suggestedSpace
        space.name = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if space.name.isEmpty { space.name = suggestedSpace.name }
        library.spaces.append(space)
        switchSpace(space.id)
        scheduleSave()
        return space.id
    }

    func setSharesData(_ id: UUID, _ shares: Bool) {
        guard let space = library.spaces.first(where: { $0.id == id }), space.sharesData != shares else { return }
        updateSpace(id, animated: false) { $0.sharesData = shares }
        for tab in space.favorites + tabIDs(in: space) {
            refreshDataStore(forTab: tab)
        }
        showToast(shares ? "Sharing logins with other spaces" : "Logins kept separate", symbol: shares ? "person.2.fill" : "lock.fill")
    }

    private func tabIDs(in space: Space) -> [UUID] {
        var ids = space.today
        for item in space.pinned {
            switch item {
            case .tab(let t): ids.append(t)
            case .folder(let f): ids.append(contentsOf: f.tabs)
            }
        }
        return ids
    }

    func updateSpace(_ id: UUID, animated: Bool = true, _ change: (inout Space) -> Void) {
        guard let s = library.spaces.firstIndex(where: { $0.id == id }) else { return }
        var space = library.spaces[s]
        change(&space)
        guard space != library.spaces[s] else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { library.spaces[s] = space }
        } else {
            library.spaces[s] = space
        }
        scheduleSave()
    }

    func openThemeEditor(_ id: UUID) {
        if !sidebarVisible {
            withAnimation(.snappy(duration: 0.28)) { sidebarVisible = true }
        }
        switchSpace(id)
        themeEditorSpace = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.themeEditorSpace = id
        }
    }

    func deleteSpace(_ id: UUID) {
        guard library.spaces.count > 1, let s = library.spaces.firstIndex(where: { $0.id == id }) else { return }
        let space = library.spaces[s]
        for t in space.favorites + tabIDs(in: space) {
            sessions[t]?.unload()
            sessions[t] = nil
            library.tabs[t] = nil
            liveOrder.removeAll { $0 == t }
        }
        if library.selectedSpace == id {
            switchSpace(library.spaces[s == 0 ? 1 : s - 1].id)
        }
        library.spaces.remove(at: s)
        dataStores[id] = nil
        if !space.sharesData {
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        }
        scheduleSave()
    }

    // MARK: - Page actions

    func goBack() { selectedSession?.webView?.goBack() }
    func goForward() { selectedSession?.webView?.goForward() }

    func reload() {
        guard let webView = selectedSession?.webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func zoom(_ delta: Double?) {
        guard let webView = selectedSession?.webView else { return }
        webView.pageZoom = delta.map { min(3, max(0.3, webView.pageZoom + $0)) } ?? 1
        showToast("Zoom \(Int((webView.pageZoom * 100).rounded()))%", symbol: "plus.magnifyingglass")
    }

    func copyURL() {
        guard let url = selectedSession?.currentURL ?? selectedRecord?.url else { return }
        copy(url)
    }

    func copyLink(_ id: UUID) {
        guard let url = (sessions[id]?.currentURL) ?? library.tabs[id]?.url else { return }
        copy(url)
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("Link copied", symbol: "link")
    }

    @ObservationIgnored var openSettingsAction: (() -> Void)?

    func openSettings(tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
        NSApp.activate()
        openSettingsAction?()
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func focusWebView() {
        guard commandBar == nil, let webView = selectedSession?.webView else { return }
        DispatchQueue.main.async { [weak self] in
            guard self?.commandBar == nil else { return }
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Chrome

    func updateTrafficLights() {
        guard let window else { return }
        let show = library.sidebarVisible || sidebarPeek || topBarVisible || window.styleMask.contains(.fullScreen)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = !show
        }
    }

    func setPeek(_ value: Bool) {
        guard sidebarPeek != value else { return }
        withAnimation(.snappy(duration: 0.22)) { sidebarPeek = value }
        updateTrafficLights()
    }

    func setTopBar(_ value: Bool) {
        guard topBarVisible != value else { return }
        withAnimation(.snappy(duration: 0.22)) { topBarVisible = value }
        updateTrafficLights()
    }

    // MARK: - Suggestions

    func historyMatches(_ query: String, limit: Int) -> [HistoryEntry] {
        let q = query.lowercased()
        let entries = history.values.filter {
            q.isEmpty || $0.url.absoluteString.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
        return Array(entries.sorted { lhs, rhs in
            let l = Double(lhs.visits) + lhs.lastVisit.timeIntervalSinceNow / 86_400
            let r = Double(rhs.visits) + rhs.lastVisit.timeIntervalSinceNow / 86_400
            return l > r
        }.prefix(limit))
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.libraryURL),
           let lib = try? decoder.decode(Library.self, from: data), !lib.spaces.isEmpty {
            library.spaces = lib.spaces
            library.tabs = lib.tabs
            library.selectedSpace = lib.selectedSpace
            library.sidebarWidth = lib.sidebarWidth
            library.sidebarVisible = lib.sidebarVisible
        } else {
            let lib = Self.seed()
            library.spaces = lib.spaces
            library.tabs = lib.tabs
            library.selectedSpace = lib.selectedSpace
        }
        if library.selectedSpace == nil || !library.spaces.contains(where: { $0.id == library.selectedSpace }) {
            library.selectedSpace = library.spaces.first?.id
        }
        if let data = try? Data(contentsOf: Self.historyURL), let entries = try? decoder.decode([HistoryEntry].self, from: data) {
            history = Dictionary(entries.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let id = currentSpace.selectedTab, library.tabs[id] != nil {
            select(id)
        }
    }

    private static func seed() -> Library {
        let library = Library()
        var space = Space(name: "Personal", symbol: "sparkles", theme: ThemePreset.lavender.theme)
        let favorites = ["https://www.google.com", "https://www.youtube.com", "https://github.com", "https://mail.google.com"]
        for string in favorites {
            let url = URL(string: string)!
            let record = TabRecord(url: url, title: url.host() ?? "", homeURL: url)
            library.tabs[record.id] = record
            space.favorites.append(record.id)
        }
        let welcome = TabRecord(url: URL(string: "https://www.apple.com/safari/")!, title: "Safari")
        library.tabs[welcome.id] = welcome
        space.today = [welcome.id]
        space.selectedTab = welcome.id
        library.spaces = [space]
        library.selectedSpace = space.id
        return library
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let lib = library
        let entries = Array(history.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(3000))
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(lib) { try? data.write(to: Self.libraryURL, options: .atomic) }
        if let data = try? encoder.encode(entries) { try? data.write(to: Self.historyURL, options: .atomic) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

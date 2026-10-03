import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(BrowserStore.self) private var store
    var floating = false

    var body: some View {
        let space = store.currentSpace
        VStack(spacing: 0) {
            header
            SidebarURLBar()
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    FavoritesGrid(space: space)
                    SpaceSection(space: space)
                }
                .id(space.id)
                .transition(.push(from: store.spaceTransitionEdge))
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .clipped()
            SidebarFooter()
        }
        .environment(\.colorScheme, store.isDark ? .dark : .light)
        .contextMenu {
            Button("New Tab") { store.commandBar = .newTab }.keyboardShortcut("t")
            Button("New Folder") { store.newFolder() }
            Button("New Live Folder…") { store.beginCreatingLiveFolder() }
            Button("New Space") { store.beginCreatingSpace() }
            Divider()
            Button("Edit Theme…") { store.openThemeEditor(store.currentSpace.id) }
            Divider()
            Button(store.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.snappy(duration: 0.28)) { store.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s")
            Divider()
            Button("Settings…") { store.openSettings() }
        }
    }

    private var header: some View {
        let session = store.selectedSession
        return ZStack {
            WindowDragArea()
            HStack(spacing: 0) {
                Spacer(minLength: 78)
                IconButton(symbol: "sidebar.left", help: store.sidebarVisible ? "Hide Sidebar (⌘S)" : "Keep Sidebar Open (⌘S)") {
                    withAnimation(.snappy(duration: 0.28)) { store.sidebarVisible.toggle() }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.left", help: "Back (⌘[)", disabled: !(session?.canGoBack ?? false)) { store.goBack() }
                IconButton(symbol: "arrow.right", help: "Forward (⌘])", disabled: !(session?.canGoForward ?? false)) { store.goForward() }
                IconButton(symbol: session?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload (⌘R)", disabled: session == nil) { store.reload() }
            }
            .padding(.trailing, 6)
        }
        .frame(height: 38)
    }
}

struct SidebarURLBar: View {
    @Environment(BrowserStore.self) private var store
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        let session = store.selectedSession
        let url = session?.currentURL ?? store.selectedRecord?.url
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        HStack(spacing: 2) {
            Button {
                store.commandBar = url == nil ? .newTab : .currentTab
            } label: {
                HStack(spacing: 6) {
                    if session?.isSecure == false, url != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(host ?? url?.absoluteString ?? "Search or enter URL")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(url == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary.opacity(0.85)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url?.absoluteString ?? "")

            if url != nil {
                SmallButton(symbol: copied ? "checkmark" : "link", help: "Copy Link (⇧⌘C)") {
                    store.copyURL()
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                }
                Menu {
                    PageMenuItems()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .help("Site controls")
            }
        }
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.1 : 0.065))
        )
        .onHover { hovering = $0 }
    }
}

struct PageMenuItems: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let url = store.selectedSession?.currentURL ?? store.selectedRecord?.url
        Button("Reload") { store.reload() }
        Button("Find in Page…") { store.findVisible = true }
        Divider()
        Button("Zoom In") { store.zoom(0.1) }
        Button("Zoom Out") { store.zoom(-0.1) }
        Button("Actual Size") { store.zoom(nil) }
        Divider()
        if let url {
            Button("Copy Link") { store.copyURL() }
            ShareLink(item: url) { Text("Share…") }
        }
        if let id = store.selectedTabID {
            Divider()
            if !store.isFavorite(id) {
                Button(store.isPinned(id) ? "Unpin Tab" : "Pin Tab") { store.togglePin(id) }
            }
            Button(store.isFavorite(id) ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(id) }
        }
    }
}

struct FavoritesGrid: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    @State private var targeted = false

    var body: some View {
        let favorites = space.favorites
        let spacing: CGFloat = 6
        let available = CGFloat(store.library.sidebarWidth) - 16
        let perRow = max(1, Int((available + spacing) / (40 + spacing)))
        let columns = max(1, min(favorites.count, perRow))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
            ForEach(Array(favorites.enumerated()), id: \.element) { index, id in
                FavoriteTile(id: id, spaceID: space.id, index: index)
            }
        }
        .frame(minHeight: favorites.isEmpty ? 30 : nil)
        .overlay {
            if favorites.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.primary.opacity(targeted ? 0.4 : 0.15))
                    .overlay(Text("Drop favorites here").font(.system(size: 11)).foregroundStyle(.tertiary))
            }
        }
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, to: .favorites(space: space.id), index: Int.max)
        } isTargeted: { targeted = $0 }
    }
}

struct FavoriteTile: View {
    @Environment(BrowserStore.self) private var store
    let id: UUID
    let spaceID: UUID
    let index: Int
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let record = store.record(id)
        let selected = store.selectedTabID == id
        let live = store.isLive(id)
        let dark = store.isDark
        let glow = selected ? FaviconStore.shared.glowColors(for: record?.homeURL ?? record?.url) : nil
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        FaviconView(url: record?.homeURL ?? record?.url, size: 17)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                ZStack {
                    shape.fill(tileFill(selected: selected, live: live, dark: dark))
                    if let glow {
                        shape.fill(LinearGradient(colors: glow, startPoint: .leading, endPoint: .trailing))
                            .opacity(0.14)
                    }
                }
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                if let glow {
                    shape.strokeBorder(LinearGradient(colors: glow, startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
                        .opacity(0.9)
                }
            }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .opacity(store.draggingTab == id ? 0.35 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.select(id) }
        .help(record?.displayTitle ?? "")
        .onDrag {
            store.beginDrag(tab: id)
            return NSItemProvider(object: DragPayload.tab(id) as NSString)
        } preview: {
            FaviconView(url: record?.url, size: 24).padding(8)
        }
        .onDrop(of: ReorderDropDelegate.types, delegate: ReorderDropDelegate(store: store, target: id, destination: .favorites(space: spaceID), targeted: $targeted))
        .contextMenu { TabMenu(id: id) }
    }

    private func tileFill(selected: Bool, live: Bool, dark: Bool) -> Color {
        if selected { return .white.opacity(dark ? 0.2 : 0.88) }
        let base: Double = live ? (dark ? 0.1 : 0.4) : (dark ? 0.04 : 0.18)
        return .white.opacity(base + (hovering ? (dark ? 0.05 : 0.12) : 0))
    }
}

struct SpaceSection: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    @State private var editing = false
    @State private var headerHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                editing = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: space.symbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text(space.name)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if headerHover {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { headerHover = $0 }
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                SpaceEditor(spaceID: space.id)
                    .environment(\.colorScheme, store.systemDark ? .dark : .light)
            }
            .background {
                Color.clear.popover(isPresented: Binding(
                    get: { store.themeEditorSpace == space.id },
                    set: { if !$0 && store.themeEditorSpace == space.id { store.themeEditorSpace = nil } }
                ), arrowEdge: .trailing) {
                    ThemeEditor(spaceID: space.id)
                        .environment(\.colorScheme, store.systemDark ? .dark : .light)
                }
            }
            .contextMenu {
                Button("Edit Theme…") { store.openThemeEditor(space.id) }
                Button("Rename Space") { editing = true }
                Button("New Tab") { store.commandBar = .newTab }
                Button("New Folder") { store.newFolder() }
                Button("New Live Folder…") { store.beginCreatingLiveFolder() }
                Divider()
                Button("Next Space") { store.switchSpace(offset: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Previous Space") { store.switchSpace(offset: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                if store.library.spaces.count > 1 {
                    Divider()
                    Button("Delete Space", role: .destructive) { store.deleteSpace(space.id) }
                }
            }

            ForEach(Array(space.pinned.enumerated()), id: \.element.id) { index, item in
                switch item {
                case .tab(let id):
                    TabRow(id: id, destination: .pinned(space: space.id), index: index)
                case .folder(let folder):
                    FolderView(folder: folder, spaceID: space.id, index: index)
                }
            }
            DropZone(destination: .pinned(space: space.id), index: Int.max, placeholder: space.pinned.isEmpty ? "Drag tabs here to pin" : nil)

            HStack(spacing: 8) {
                Rectangle()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 1)
                if !space.today.isEmpty {
                    Button {
                        withAnimation(.snappy) { store.clearToday() }
                    } label: {
                        Label("Clear", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Close all unpinned tabs (⇧⌘K)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            NewTabRow()

            ForEach(Array(space.today.enumerated()), id: \.element) { index, id in
                TabRow(id: id, destination: .today(space: space.id), index: index)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            DropZone(destination: .today(space: space.id), index: Int.max, placeholder: nil)
                .frame(minHeight: 60, alignment: .top)
        }
        .animation(.snappy(duration: 0.25), value: space.today)
    }
}

struct NewTabRow: View {
    @Environment(BrowserStore.self) private var store
    @State private var hovering = false

    var body: some View {
        Button {
            store.commandBar = .newTab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer()
                if hovering {
                    Text("⌘T").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct TabRow: View {
    @Environment(BrowserStore.self) private var store
    let id: UUID
    let destination: Destination
    let index: Int
    var indent: CGFloat = 0
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let record = store.record(id)
        let selected = store.selectedTabID == id
        let live = store.isLive(id)
        let pinned: Bool = { if case .today = destination { false } else { true } }()
        let dark = store.isDark
        let asleep = pinned && !live && !selected
        HStack(spacing: 8) {
            FaviconView(url: record?.homeURL ?? record?.url, size: 15)
                .saturation(asleep ? 0.2 : 1)
                .opacity(asleep ? 0.55 : 1)
            Text(record?.displayTitle ?? "")
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(.primary.opacity(asleep ? 0.55 : 0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering, pinned, let record, record.isAwayFromHome {
                SmallButton(symbol: "arrow.uturn.backward", help: "Back to pinned page") { store.resetToHome(id) }
            }
            if hovering && (!pinned || live) {
                SmallButton(symbol: pinned ? "minus" : "xmark", help: pinned ? "Unload tab" : "Close tab (⌘W)") {
                    withAnimation(.snappy(duration: 0.2)) { store.close(id) }
                }
            }
        }
        .padding(.leading, 9 + indent)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(dark ? 0.16 : 0.85) : Color.primary.opacity(hovering ? (dark ? 0.08 : 0.06) : (pinned && live ? 0.035 : 0)))
                .shadow(color: .black.opacity(selected && !dark ? 0.08 : 0), radius: 1.5, y: 1)
        }
        .overlay(alignment: .top) {
            if targeted && store.draggingTab == nil && store.draggingFolder == nil { InsertionLine().offset(y: -2) }
        }
        .opacity(store.draggingTab == id ? 0.35 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.select(id) }
        .onDrag {
            store.beginDrag(tab: id)
            return NSItemProvider(object: DragPayload.tab(id) as NSString)
        } preview: {
            HStack(spacing: 8) {
                FaviconView(url: record?.url, size: 16)
                Text(record?.displayTitle ?? "").font(.system(size: 12.5)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(width: 200, height: 30, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
        .onDrop(of: ReorderDropDelegate.types, delegate: ReorderDropDelegate(store: store, target: id, destination: destination, targeted: $targeted))
        .contextMenu { TabMenu(id: id) }
    }
}

struct FolderView: View {
    @Environment(BrowserStore.self) private var store
    let folder: Folder
    let spaceID: UUID
    let index: Int
    @State private var hovering = false
    @State private var targeted = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let editing = store.editingFolder == folder.id
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                if let live = folder.live {
                    FaviconView(url: live.siteURL ?? live.url, size: 15)
                        .frame(width: 16)
                } else {
                    Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                if editing {
                    TextField("Folder name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onExitCommand(perform: commit)
                        .onAppear {
                            name = folder.name
                            DispatchQueue.main.async { nameFocused = true }
                        }
                        .onChange(of: nameFocused) { if !nameFocused { commit() } }
                } else {
                    Text(folder.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let live = folder.live, !editing {
                    if store.refreshingFolders.contains(folder.id) {
                        ProgressView().controlSize(.mini)
                    } else if let error = live.error {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .help(error)
                    }
                    if live.unreadCount > 0 && !hovering {
                        Text("\(live.unreadCount)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(store.palette.accent, in: Capsule())
                            .padding(.trailing, 2)
                    }
                }
                if hovering && !editing {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .padding(.trailing, 6)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(targeted ? 0.12 : hovering ? 0.06 : 0))
            }
            .opacity(store.draggingFolder == folder.id ? 0.35 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture {
                guard !editing else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    store.updateFolder(folder.id) { $0.isExpanded.toggle() }
                }
            }
            .onDrag {
                store.beginDrag(folder: folder.id)
                return NSItemProvider(object: DragPayload.folder(folder.id) as NSString)
            } preview: {
                Label(folder.name, systemImage: "folder.fill")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .onDrop(of: ReorderDropDelegate.types, delegate: ReorderDropDelegate(
                store: store, target: folder.id, destination: .pinned(space: spaceID),
                intoFolder: folder.live == nil ? .folder(space: spaceID, folder: folder.id) : nil, targeted: $targeted
            ))
            .contextMenu {
                if let live = folder.live {
                    Button("Refresh") { Task { await store.refreshLiveFolder(folder.id) } }
                    Button("Mark All as Read") { store.setLiveItemRead(nil, in: folder.id, read: true) }
                        .disabled(live.unreadCount == 0)
                    Divider()
                }
                Button("Rename") { store.editingFolder = folder.id }
                Button(folder.isExpanded ? "Collapse" : "Expand") {
                    store.updateFolder(folder.id) { $0.isExpanded.toggle() }
                }
                Divider()
                Button("Delete Folder") { store.deleteFolder(folder.id) }
            }

            if folder.isExpanded, let live = folder.live {
                ForEach(live.visibleItems) {
                    LiveItemRow(item: $0, folderID: folder.id)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if live.items.isEmpty {
                    Text(live.error ?? (store.refreshingFolders.contains(folder.id) ? "Loading…" : "No posts yet"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .padding(.leading, 38)
                        .frame(minHeight: 22)
                }
            } else if folder.isExpanded {
                ForEach(Array(folder.tabs.enumerated()), id: \.element) { tabIndex, id in
                    TabRow(id: id, destination: .folder(space: spaceID, folder: folder.id), index: tabIndex, indent: 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if folder.tabs.isEmpty {
                    Text("Empty folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 38)
                        .frame(height: 22)
                }
            }
        }
    }

    private func commit() {
        guard store.editingFolder == folder.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        store.updateFolder(folder.id) { $0.name = trimmed.isEmpty ? "Folder" : trimmed }
        store.editingFolder = nil
    }
}

struct DropZone: View {
    @Environment(BrowserStore.self) private var store
    let destination: Destination
    let index: Int
    let placeholder: String?
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .top) {
            if let placeholder {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .frame(height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.primary.opacity(targeted ? 0.35 : 0.12))
                    }
            }
            if targeted && placeholder == nil { InsertionLine() }
        }
        .frame(maxWidth: .infinity, minHeight: placeholder == nil ? 10 : 28, alignment: .top)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, to: destination, index: index)
        } isTargeted: { targeted = $0 }
    }
}

struct ReorderDropDelegate: DropDelegate {
    static let types: [UTType] = [.plainText, .utf8PlainText, .url]

    let store: BrowserStore
    let target: UUID
    let destination: Destination
    var intoFolder: Destination?
    @Binding var targeted: Bool

    func dropEntered(info: DropInfo) {
        targeted = true
        MainActor.assumeIsolated {
            guard intoFolder == nil || store.draggingFolder != nil else { return }
            if store.liveReorder(onto: target, in: destination) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return MainActor.assumeIsolated {
            if let folder = intoFolder, let tab = store.draggingTab {
                store.move(.tab(tab), to: folder, index: Int.max)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            if store.draggingTab != nil || store.draggingFolder != nil {
                store.endDrag()
                return true
            }
            let drop = intoFolder ?? destination
            let index = intoFolder == nil ? (store.ids(in: destination).firstIndex(of: target) ?? Int.max) : Int.max
            for provider in info.itemProviders(for: Self.types) {
                if provider.canLoadObject(ofClass: NSURL.self) {
                    _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                        guard let string = (url as? URL)?.absoluteString else { return }
                        DispatchQueue.main.async { _ = store.handleDrop([string], to: drop, index: index) }
                    }
                } else {
                    _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                        guard let string = text as? String else { return }
                        DispatchQueue.main.async { _ = store.handleDrop([string], to: drop, index: index) }
                    }
                }
            }
            return true
        }
    }
}

struct InsertionLine: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let accent = store.palette.accent
        HStack(spacing: 0) {
            Circle().strokeBorder(accent, lineWidth: 1.5).frame(width: 6, height: 6)
            Rectangle().fill(accent).frame(height: 2)
        }
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }
}

struct SmallButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.primary.opacity(hovering ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct FaviconView: View {
    let url: URL?
    let size: CGFloat
    private var favicons = FaviconStore.shared

    init(url: URL?, size: CGFloat) {
        self.url = url
        self.size = size
    }

    var body: some View {
        Group {
            if let image = favicons.icon(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                let letter = url?.host()?.replacingOccurrences(of: "www.", with: "").first.map { String($0).uppercased() } ?? ""
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(.primary.opacity(0.15))
                    .overlay {
                        if letter.isEmpty {
                            Image(systemName: "globe").font(.system(size: size * 0.6)).foregroundStyle(.secondary)
                        } else {
                            Text(letter).font(.system(size: size * 0.6, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct TabMenu: View {
    @Environment(BrowserStore.self) private var store
    let id: UUID

    var body: some View {
        let record = store.record(id)
        let isFavorite = store.isFavorite(id)
        let pinned = store.isPinned(id)

        Button("Copy Link") { store.copyLink(id) }
        Button("Duplicate") { store.duplicate(id) }
        Divider()
        if !isFavorite {
            Button(pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(id) }
        }
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(id) }
        Menu("Move to Folder") {
            Button("New Folder") { store.newFolder(with: id) }
            if !store.folders.isEmpty { Divider() }
            ForEach(store.folders) { folder in
                Button(folder.name) {
                    store.move(.tab(id), to: .folder(space: store.currentSpace.id, folder: folder.id), index: Int.max)
                }
            }
        }
        if store.library.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(store.library.spaces.filter { $0.id != store.currentSpace.id }) { space in
                    Button(space.name) {
                        let destination: Destination = isFavorite ? .favorites(space: space.id) : pinned ? .pinned(space: space.id) : .today(space: space.id)
                        store.move(.tab(id), to: destination, index: pinned ? Int.max : 0)
                        if store.selectedTabID == id { store.select(nil) }
                    }
                }
            }
        }
        if pinned, record?.isAwayFromHome == true {
            Button("Back to Pinned Page") { store.resetToHome(id) }
        }
        Divider()
        Button("Edit Space Theme…") { store.openThemeEditor(store.currentSpace.id) }
        Divider()
        if pinned {
            if store.isLive(id) { Button("Unload Tab") { store.close(id) } }
            Button("Close and Remove") {
                store.move(.tab(id), to: .today(space: store.currentSpace.id), index: 0)
                store.close(id)
            }
        } else {
            Button("Close Tab") { store.close(id) }
        }
    }
}

struct SidebarFooter: View {
    @Environment(BrowserStore.self) private var store
    @State private var showDownloads = false
    private var downloads = DownloadCenter.shared

    var body: some View {
        HStack(spacing: 2) {
            if !downloads.items.isEmpty {
                IconButton(symbol: downloads.active ? "arrow.down.circle.dotted" : "arrow.down.circle", help: "Downloads") {
                    showDownloads.toggle()
                }
                .popover(isPresented: $showDownloads, arrowEdge: .top) {
                    DownloadsList().environment(\.colorScheme, store.systemDark ? .dark : .light)
                }
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
            Spacer(minLength: 4)
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(store.library.spaces) { space in
                        SpaceDot(space: space)
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            Menu {
                Button("New Space") { store.beginCreatingSpace() }
                Button("New Folder") { store.newFolder() }
                Button("New Live Folder…") { store.beginCreatingLiveFolder() }
                Button("New Tab") { store.commandBar = .newTab }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 28)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

struct SpaceDot: View {
    @Environment(BrowserStore.self) private var store
    let space: Space
    @State private var hovering = false

    var body: some View {
        let selected = store.currentSpace.id == space.id
        Button {
            store.switchSpace(space.id)
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(.primary.opacity(selected ? 0.85 : (hovering ? 0.55 : 0.35)))
                .background(.primary.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(space.name)
        .contextMenu {
            Button("Switch to \(space.name)") { store.switchSpace(space.id) }
            Button("Edit Theme…") { store.openThemeEditor(space.id) }
            if store.library.spaces.count > 1 {
                Divider()
                Button("Delete Space") { store.deleteSpace(space.id) }
            }
        }
    }
}

struct SpaceEditor: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spaceID: UUID
    @State private var name = ""

    var body: some View {
        let space = store.library.spaces.first { $0.id == spaceID }
        VStack(alignment: .leading, spacing: 14) {
            TextField("Space name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveName)
                .onChange(of: name) { saveName() }

            Button {
                dismiss()
                store.openThemeEditor(spaceID)
            } label: {
                HStack(spacing: 10) {
                    if let space {
                        ThemeBackground(palette: space.theme.palette(systemDark: store.systemDark))
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                    }
                    Text("Edit Theme…").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Icon").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                ForEach(Space.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.primary.opacity(space?.symbol == symbol ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { store.updateSpace(spaceID) { $0.symbol = symbol } }
                }
            }

            Divider()
            Toggle(isOn: Binding(
                get: { space?.sharesData ?? true },
                set: { store.setSharesData(spaceID, $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share logins & site data").font(.system(size: 12, weight: .medium))
                    Text((space?.sharesData ?? true) ? "Signed in wherever your other spaces are" : "Cookies and logins stay in this space")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if store.library.spaces.count > 1 {
                Divider()
                Button("Delete Space", role: .destructive) { store.deleteSpace(spaceID) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 236)
        .onAppear { name = space?.name ?? "" }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.updateSpace(spaceID) { $0.name = trimmed }
    }
}

struct DownloadsList: View {
    private var center = DownloadCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(center.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.failed ? "exclamationmark.circle.fill" : "doc.fill")
                        .foregroundStyle(item.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.filename).font(.system(size: 12)).lineLimit(1)
                        if !item.finished && !item.failed {
                            ProgressView(value: item.progress).controlSize(.small)
                        }
                    }
                    Spacer()
                    if item.finished {
                        Button {
                            center.reveal(item)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

extension TabRecord {
    var isAwayFromHome: Bool {
        guard let home = homeURL, let url else { return false }
        func normalized(_ u: URL) -> String {
            let host = (u.host() ?? "").replacingOccurrences(of: "www.", with: "")
            return host + u.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return normalized(home) != normalized(url)
    }
}

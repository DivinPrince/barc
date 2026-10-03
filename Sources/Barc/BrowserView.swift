import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var dragStartWidth: Double?

    private let inset = MouseTracker.cardInset

    var body: some View {
        let width = store.library.sidebarWidth
        ZStack(alignment: .topLeading) {
            background

            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: width)
                        .overlay(alignment: .trailing) { resizeHandle }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 0) {
                    if store.topBarVisible {
                        TopBar()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    ContentCard()
                        .padding(.top, store.topBarVisible ? 0 : inset)
                }
                .padding(.bottom, inset)
                .padding(.trailing, inset)
                .padding(.leading, store.sidebarVisible ? 0 : inset)
            }

            if !store.sidebarVisible && store.sidebarPeek {
                SidebarView(floating: true)
                    .frame(width: width)
                    .background {
                        ZStack {
                            VisualEffect(material: .sidebar)
                            ThemeBackground(palette: store.palette, opacity: 0.92)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 18, x: 4)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .padding(.vertical, inset)
                    .padding(.leading, 4)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }

            if let mode = store.commandBar {
                CommandBarView(mode: mode)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(3)
            }

            if store.creatingSpace {
                SpaceOnboarding(initial: store.suggestedSpace)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(4)
            }

            if store.creatingLiveFolder {
                LiveFolderSheet()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(4)
            }
        }
        .animation(.snappy(duration: 0.18), value: store.commandBar)
        .animation(.snappy(duration: 0.22), value: store.creatingSpace)
        .animation(.snappy(duration: 0.22), value: store.creatingLiveFolder)
        .background(WindowAccessor(store: store))
        .onAppear { store.openSettingsAction = { openSettings() } }
        .ignoresSafeArea()
        .frame(minWidth: 720, minHeight: 480)
    }

    private var background: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground)
            ThemeBackground(palette: store.palette, opacity: store.isDark ? 0.94 : 0.88)
        }
        .ignoresSafeArea()
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? store.library.sidebarWidth
                        dragStartWidth = start
                        store.library.sidebarWidth = min(420, max(200, start + value.translation.width))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        store.scheduleSave()
                    }
            )
            .offset(x: 4)
    }
}

struct ContentCard: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let session = store.selectedSession
        ZStack(alignment: .top) {
            if let session, session.isLive {
                WebContainer(session: session)
            } else {
                EmptyStateView()
            }

            if let session {
                ProgressLine(session: session, color: store.palette.accent)
            }

            if store.findVisible, let session {
                FindBar(session: session)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            DownloadToast()

            if let toast = store.toast {
                ToastView(toast: toast)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, DownloadCenter.shared.toast == nil ? 16 : 62)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    .id(toast.id)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
        }
        .animation(.snappy(duration: 0.2), value: store.findVisible)
    }
}

struct ProgressLine: View {
    let session: TabSession
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                .frame(width: proxy.size.width * max(0.05, session.progress), height: 2.5)
                .opacity(session.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: session.progress)
                .animation(.easeOut(duration: 0.4), value: session.isLoading)
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

struct EmptyStateView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        ZStack {
            store.palette.accent.opacity(0.06)
            VStack(spacing: 18) {
                Image(systemName: store.currentSpace.symbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(store.palette.accent)
                Text(store.currentSpace.name)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.8))
                Button {
                    store.commandBar = .newTab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        Text("Search or enter address")
                        Spacer()
                        Text("⌘T")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(width: 380, height: 42)
                    .background(.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                }
                .buttonStyle(.plain)

                HStack(spacing: 18) {
                    ShortcutHint(keys: "⌘S", label: "Sidebar")
                    ShortcutHint(keys: "⌘D", label: "Pin tab")
                    ShortcutHint(keys: "⌥⌘→", label: "Next space")
                }
                .padding(.top, 6)
            }
        }
    }
}

struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
    }
}

struct TopBar: View {
    @Environment(BrowserStore.self) private var store
    @State private var copied = false
    @State private var urlHover = false

    var body: some View {
        let session = store.selectedSession
        let url = session?.currentURL ?? store.selectedRecord?.url
        let leading: CGFloat = (store.sidebarVisible ? 2 : 74) + CGFloat(store.sidebarVisible ? 3 : 4) * 28
        let pinned = ExtensionManager.shared.pinnedContexts
        let trailing: CGFloat = 2 + 28 * 2 + 30 + CGFloat(pinned.count) * 28
        GeometryReader { proxy in
            let side = max(leading, trailing) + 12
            let pillWidth = min(620, max(160, proxy.size.width - side * 2))
            ZStack {
                HStack(spacing: 2) {
                    if !store.sidebarVisible {
                        IconButton(symbol: "sidebar.left", help: "Show Sidebar (⌘S)") {
                            withAnimation(.snappy(duration: 0.28)) { store.sidebarVisible = true }
                        }
                    }
                    IconButton(symbol: "chevron.left", help: "Back", disabled: !(session?.canGoBack ?? false)) { store.goBack() }
                    IconButton(symbol: "chevron.right", help: "Forward", disabled: !(session?.canGoForward ?? false)) { store.goForward() }
                    IconButton(symbol: session?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Reload") { store.reload() }

                    Spacer(minLength: 0)

                    ForEach(pinned, id: \.uniqueIdentifier) { context in
                        PinnedExtensionButton(context: context)
                    }
                    IconButton(symbol: copied ? "checkmark" : "link", help: "Copy Link (⇧⌘C)") {
                        store.copyURL()
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                    }
                    IconButton(symbol: "magnifyingglass", help: "Find (⌘F)") { store.findVisible = true }
                    Menu {
                        PageMenuItems()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                    .background(ExtensionPopupAnchor(key: ExtensionPopup.menuAnchor))
                }
                .padding(.leading, store.sidebarVisible ? 2 : 74)
                .padding(.trailing, 2)

                Button {
                    store.commandBar = .currentTab
                } label: {
                    HStack(spacing: 6) {
                        if url != nil {
                            Image(systemName: session?.isSecure == false ? "exclamationmark.triangle.fill" : "lock.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(session?.isSecure == false ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        }
                        URLText(url: url)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: pillWidth, height: 28)
                    .background(.primary.opacity(urlHover ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { urlHover = $0 }
                .help(url?.absoluteString ?? "")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: MouseTracker.topBarHeight)
        .background(WindowDragArea())
        .environment(\.colorScheme, store.isDark ? .dark : .light)
    }
}

struct URLText: View {
    let url: URL?

    var body: some View {
        if let url, let host = url.host() {
            let path = url.path().split(separator: "/").map(String.init)
            let rest = path.isEmpty ? "" : " / " + path.joined(separator: " / ")
            (Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host).foregroundStyle(.primary)
                + Text(rest).foregroundStyle(.tertiary))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(url?.absoluteString ?? "Search or enter address")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var disabled = false
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(hovering && !disabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct FindBar: View {
    @Environment(BrowserStore.self) private var store
    let session: TabSession
    @State private var query = ""
    @State private var notFound = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            TextField("Find in page", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { find(backwards: false) }
                .onChange(of: query) { find(backwards: false) }
            if notFound && !query.isEmpty {
                Text("No matches").font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
            }
            IconButton(symbol: "chevron.up", size: 11) { find(backwards: true) }
            IconButton(symbol: "chevron.down", size: 11) { find(backwards: false) }
            IconButton(symbol: "xmark", size: 11) { close() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(width: 330, height: 38)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private func find(backwards: Bool) {
        guard let webView = session.webView, !query.isEmpty else {
            notFound = false
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(query, configuration: config) { result in
            notFound = !result.matchFound
        }
    }

    private func close() {
        store.findVisible = false
        store.focusWebView()
    }
}

struct ToastView: View {
    @Environment(BrowserStore.self) private var store
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(store.palette.accent)
                .frame(width: 22, height: 22)
                .background(store.palette.accent.opacity(0.14), in: Circle())
            Text(toast.text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .allowsHitTesting(false)
    }
}

struct DownloadToast: View {
    private var center = DownloadCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let item = center.toast {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    Text(item.filename)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Button("Show in Finder") { center.reveal(item) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: center.toast?.id)
    }
}

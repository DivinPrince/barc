import AppKit
import SwiftUI

struct LiveItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var url: URL
    var date: Date?
    var isRead = false
    var tab: UUID?
}

struct LiveFeed: Codable, Equatable {
    var url: URL
    var siteURL: URL?
    var items: [LiveItem] = []
    var lastRefresh: Date?
    var error: String?

    static let itemLimit = 5

    var visibleItems: [LiveItem] {
        items.enumerated().filter { $0.offset < Self.itemLimit || $0.element.tab != nil }.map(\.element)
    }

    var unreadCount: Int { visibleItems.filter { !$0.isRead }.count }

    mutating func apply(_ document: FeedDocument, at date: Date = Date()) {
        let known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let firstLoad = lastRefresh == nil
        var seen = Set<String>()
        let fresh = document.items
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.itemLimit)
            .map { item in
                var item = item
                item.isRead = known[item.id]?.isRead ?? firstLoad
                item.tab = known[item.id]?.tab
                return item
            }
        let freshIDs = Set(fresh.map(\.id))
        items = fresh + items.filter { $0.tab != nil && !freshIDs.contains($0.id) }
        siteURL = document.siteURL ?? siteURL
        lastRefresh = date
        error = nil
    }
}

struct FeedDocument: Equatable {
    var title: String?
    var siteURL: URL?
    var items: [LiveItem]
}

enum GitHubFeed: String, CaseIterable, Identifiable {
    case pullRequests, releases, commits, tags, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pullRequests: "Pull Requests"
        case .releases: "Releases"
        case .commits: "Commits"
        case .tags: "Tags"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .pullRequests: "arrow.triangle.pull"
        case .releases: "shippingbox"
        case .commits: "arrow.triangle.branch"
        case .tags: "tag"
        case .activity: "person.crop.circle"
        }
    }

    var isPerUser: Bool { self == .pullRequests || self == .activity }

    var placeholder: String { isPerUser ? "username" : "owner/repo" }

    var example: String { isPerUser ? "torvalds" : "apple/swift" }

    var summary: String {
        switch self {
        case .pullRequests: "Open pull requests by this user across all public repositories."
        case .releases: "New releases published in a repository."
        case .commits: "Recent commits on the default branch, or on a branch from a github.com/owner/repo/tree/branch link."
        case .tags: "New tags pushed to a repository."
        case .activity: "A user's public activity: pushes, stars, issues, and pull requests."
        }
    }

    func feed(for input: String) -> (url: URL, name: String)? {
        let parts = Self.path(input)
        let valid = parts.prefix(2).allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }
        guard valid, let owner = parts.first else { return nil }
        if isPerUser, parts.count != 1 { return nil }
        if self == .activity {
            return URL(string: "https://github.com/\(owner).atom").map { ($0, owner) }
        }
        if self == .pullRequests {
            var components = URLComponents(string: "https://api.github.com/search/issues")!
            components.queryItems = [
                URLQueryItem(name: "q", value: "is:pr is:open author:\(owner)"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "per_page", value: "25"),
            ]
            return components.url.map { ($0, "\(owner) Pull Requests") }
        }
        guard parts.count >= 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let base = "https://github.com/\(owner)/\(repo)"
        switch self {
        case .releases:
            return URL(string: "\(base)/releases.atom").map { ($0, "\(repo) Releases") }
        case .tags:
            return URL(string: "\(base)/tags.atom").map { ($0, "\(repo) Tags") }
        case .commits:
            guard parts.count > 3, parts[2] == "tree" else {
                return URL(string: "\(base)/commits.atom").map { ($0, "\(repo) Commits") }
            }
            let branch = parts[3...].joined(separator: "/")
            let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            return URL(string: "\(base)/commits/\(encoded).atom").map { ($0, "\(repo) · \(branch)") }
        case .pullRequests, .activity:
            return nil
        }
    }

    static func parsePulls(_ data: Data, apiURL: URL) -> FeedDocument? {
        struct Pull: Decodable {
            let id: Int
            let title: String
            let htmlUrl: URL
            let updatedAt: Date?
        }
        struct Search: Decodable {
            let items: [Pull]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard let pulls = (try? decoder.decode([Pull].self, from: data)) ?? (try? decoder.decode(Search.self, from: data))?.items else { return nil }
        let path = apiURL.path()
        let site = path.hasPrefix("/repos/") ? path.replacingOccurrences(of: "/repos/", with: "https://github.com/", options: .anchored) : "https://github.com/pulls"
        return FeedDocument(
            title: nil,
            siteURL: URL(string: site),
            items: pulls.map { LiveItem(id: String($0.id), title: $0.title, url: $0.htmlUrl, date: $0.updatedAt) }
        )
    }

    static func path(_ input: String) -> [String] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" {
            text = url.path()
        } else if let range = text.range(of: "github.com/", options: [.caseInsensitive, .anchored]) {
            text = String(text[range.upperBound...])
        }
        return text.split(separator: "/").map(String.init)
    }

    func prefill(from url: URL?) -> String? {
        guard let url, url.host()?.lowercased().hasSuffix("github.com") == true else { return nil }
        let reserved: Set<String> = ["settings", "notifications", "pulls", "issues", "explore", "marketplace", "login", "new", "orgs", "search"]
        let parts = Self.path(url.absoluteString)
        guard let first = parts.first, !reserved.contains(first.lowercased()) else { return nil }
        if isPerUser { return first }
        return parts.count >= 2 ? parts.prefix(2).joined(separator: "/") : nil
    }
}

final class FeedParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var isFeed = false
    private var title: String?
    private var siteURL: URL?
    private var items: [LiveItem] = []
    private var stack: [String] = []
    private var text = ""
    private var entry: [String: String]?

    private init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func parse(_ data: Data, baseURL: URL) -> FeedDocument? {
        let delegate = FeedParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard delegate.isFeed else { return nil }
        return FeedDocument(title: delegate.title, siteURL: delegate.siteURL, items: delegate.items)
    }

    static func discover(in html: String, baseURL: URL) -> URL? {
        for tag in html.matches(of: #/<link\b[^>]*>/#.ignoresCase()) {
            var attributes: [String: String] = [:]
            for match in tag.output.matches(of: #/([\w-]+)\s*=\s*["']([^"']*)["']/#) {
                attributes[match.output.1.lowercased()] = String(match.output.2)
            }
            guard let type = attributes["type"]?.lowercased(), type == "application/rss+xml" || type == "application/atom+xml",
                  attributes["rel"]?.lowercased().split(separator: " ").contains("alternate") == true,
                  let href = attributes["href"]?.replacingOccurrences(of: "&amp;", with: "&"),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            return url
        }
        return nil
    }

    static func date(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = Self.localName(elementName)
        if stack.isEmpty {
            isFeed = ["rss", "feed", "rdf"].contains(name)
            if !isFeed { parser.abortParsing() }
        }
        if name == "item" || name == "entry" {
            entry = [:]
        } else if name == "link", let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" {
            if entry != nil, stack.last == "item" || stack.last == "entry" {
                if entry?["link"] == nil { entry?["link"] = href }
            } else if entry == nil, siteURL == nil {
                siteURL = URL(string: href, relativeTo: baseURL)?.absoluteURL
            }
        }
        stack.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.localName(elementName)
        stack.removeLast()
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = ""
        let parent = stack.last
        if name == "item" || name == "entry" {
            finishEntry()
        } else if entry != nil, parent == "item" || parent == "entry", !value.isEmpty {
            let key: String? = switch name {
            case "title", "link": name
            case "guid", "id": "id"
            case "pubdate", "published", "updated", "date": "date"
            default: nil
            }
            if let key, entry?[key] == nil { entry?[key] = value }
        } else if entry == nil, parent == "channel" || parent == "feed", !value.isEmpty {
            if name == "title", title == nil { title = value }
            if name == "link", siteURL == nil { siteURL = URL(string: value, relativeTo: baseURL)?.absoluteURL }
        }
    }

    private func finishEntry() {
        defer { entry = nil }
        guard let entry, let link = entry["link"],
              let url = URL(string: link, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.hasPrefix("http") == true else { return }
        let title = entry["title"] ?? url.host() ?? url.absoluteString
        items.append(LiveItem(id: entry["id"] ?? url.absoluteString, title: title, url: url, date: entry["date"].flatMap(Self.date)))
    }
}

enum FeedError: LocalizedError {
    case notAFeed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notAFeed: "No RSS or Atom feed found at that address."
        case .http(404): "Not found (404). Check the name and that it's public."
        case .http(403), .http(429): "GitHub's rate limit was reached. Try again in a few minutes."
        case .http(let code): "The server responded with an error (\(code))."
        }
    }
}

enum FeedLoader {
    static func load(_ url: URL) async throws -> (url: URL, document: FeedDocument) {
        if url.host() == "api.github.com" {
            guard let document = GitHubFeed.parsePulls(try await fetch(url, accept: "application/vnd.github+json"), apiURL: url) else {
                throw FeedError.notAFeed
            }
            return (url, document)
        }
        let data = try await fetch(url)
        if let document = FeedParser.parse(data, baseURL: url) { return (url, document) }
        if let feedURL = FeedParser.discover(in: String(decoding: data, as: UTF8.self), baseURL: url), feedURL != url,
           let document = FeedParser.parse(try await fetch(feedURL), baseURL: feedURL) {
            return (feedURL, document)
        }
        throw FeedError.notAFeed
    }

    private static func fetch(_ url: URL, accept: String = "application/atom+xml, application/rss+xml, application/xml;q=0.9, text/html;q=0.8, */*;q=0.5") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        return data
    }
}

extension BrowserStore {
    static let liveRefreshInterval: TimeInterval = 15 * 60

    func beginCreatingLiveFolder() {
        commandBar = nil
        themeEditorSpace = nil
        creatingLiveFolder = true
    }

    func liveFeed(_ folderID: UUID) -> LiveFeed? {
        for space in library.spaces {
            for case .folder(let folder) in space.pinned where folder.id == folderID {
                return folder.live
            }
        }
        return nil
    }

    @discardableResult
    func addLiveFolder(name: String, feedURL: URL, document: FeedDocument) -> UUID {
        var feed = LiveFeed(url: feedURL)
        feed.apply(document)
        let folder = Folder(name: name, live: feed)
        withAnimation(.snappy(duration: 0.25)) {
            library.spaces[spaceIndex].pinned.insert(.folder(folder), at: 0)
        }
        scheduleSave()
        return folder.id
    }

    func refreshLiveFolder(_ id: UUID) async {
        guard let feed = liveFeed(id), !refreshingFolders.contains(id) else { return }
        refreshingFolders.insert(id)
        defer { refreshingFolders.remove(id) }
        do {
            let document = try await FeedLoader.load(feed.url).document
            updateFolder(id) { $0.live?.apply(document) }
        } catch {
            updateFolder(id) { $0.live?.error = error.localizedDescription }
        }
    }

    func refreshLiveFolders(olderThan age: TimeInterval = 0) {
        for space in library.spaces {
            for case .folder(let folder) in space.pinned {
                guard let live = folder.live, (live.lastRefresh ?? .distantPast).timeIntervalSinceNow <= -age else { continue }
                Task { await refreshLiveFolder(folder.id) }
            }
        }
    }

    func openLiveItem(_ item: LiveItem, folder: UUID, background: Bool = false) {
        setLiveItemRead(item.id, in: folder, read: true)
        if let tab = liveFeed(folder)?.items.first(where: { $0.id == item.id })?.tab, case .folder(_, folder)? = location(of: tab) {
            if !background { select(tab) }
            return
        }
        guard let space = library.spaces.first(where: { space in space.pinned.contains { $0.id == folder } }) else { return }
        let tab = newTab(item.url, background: background, at: .folder(space: space.id, folder: folder), index: Int.max)
        updateFolder(folder) { folder in
            guard let index = folder.live?.items.firstIndex(where: { $0.id == item.id }) else { return }
            folder.live?.items[index].tab = tab
        }
    }

    func forgetLiveTab(_ tab: UUID, in folder: UUID) {
        updateFolder(folder) { folder in
            guard var live = folder.live else { return }
            for index in live.items.indices where live.items[index].tab == tab {
                live.items[index].tab = nil
            }
            live.items = live.items.enumerated().filter { $0.offset < LiveFeed.itemLimit || $0.element.tab != nil }.map(\.element)
            folder.live = live
        }
    }

    func setLiveItemRead(_ itemID: String?, in folder: UUID, read: Bool) {
        updateFolder(folder) { folder in
            guard var live = folder.live else { return }
            for index in live.items.indices where itemID == nil || live.items[index].id == itemID {
                live.items[index].isRead = read
            }
            folder.live = live
        }
    }
}

struct LiveItemRow: View {
    @Environment(BrowserStore.self) private var store
    let item: LiveItem
    let folderID: UUID
    @State private var hovering = false

    var body: some View {
        let tab = item.tab.flatMap { id -> UUID? in
            if case .folder(_, folderID)? = store.location(of: id) { id } else { nil }
        }
        let selected = tab != nil && store.selectedTabID == tab
        let live = tab.map(store.isLive) ?? false
        let dark = store.isDark
        HStack(spacing: 8) {
            FaviconView(url: item.url, size: 15)
                .opacity(item.isRead ? 0.6 : 1)
            Text(item.title)
                .font(.system(size: 12.5, weight: item.isRead ? .regular : .medium))
                .foregroundStyle(.primary.opacity(item.isRead ? 0.6 : 0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering, let tab {
                SmallButton(symbol: "xmark", help: "Close tab") {
                    withAnimation(.snappy(duration: 0.2)) { store.close(tab) }
                }
            } else if !item.isRead {
                Circle()
                    .fill(store.palette.accent)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 7)
            }
        }
        .padding(.leading, 23)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.white.opacity(dark ? 0.16 : 0.85) : Color.primary.opacity(hovering ? (dark ? 0.08 : 0.06) : (live ? 0.035 : 0)))
                .shadow(color: .black.opacity(selected && !dark ? 0.08 : 0), radius: 1.5, y: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openLiveItem(item, folder: folderID) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(item.date.map { "\(item.title)\n\($0.formatted(date: .abbreviated, time: .shortened))" } ?? item.title)
        .contextMenu {
            Button("Open") { store.openLiveItem(item, folder: folderID) }
            Button("Open in Background") { store.openLiveItem(item, folder: folderID, background: true) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
                store.showToast("Link copied", symbol: "link")
            }
            Divider()
            Button(item.isRead ? "Mark as Unread" : "Mark as Read") {
                store.setLiveItemRead(item.id, in: folderID, read: !item.isRead)
            }
            if let tab {
                Divider()
                Button("Close Tab") { store.close(tab) }
            }
        }
    }
}

struct LiveFolderSheet: View {
    @Environment(BrowserStore.self) private var store

    enum Source: String, CaseIterable, Identifiable {
        case github = "GitHub"
        case rss = "RSS Feed"

        var id: String { rawValue }
    }

    @State private var source: Source = .github
    @State private var kind: GitHubFeed = .pullRequests
    @State private var githubInput = ""
    @State private var feedInput = ""
    @State private var loading = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if source == .github { githubForm } else { rssForm }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .padding(22)
            .frame(width: 440)
            .background {
                ZStack {
                    VisualEffect(material: .popover, blending: .withinWindow)
                    Color(nsColor: .windowBackgroundColor).opacity(0.85)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
            .environment(\.colorScheme, store.systemDark ? .dark : .light)
            .animation(.snappy(duration: 0.2), value: source)
        }
        .onAppear {
            let current = store.selectedRecord?.url
            githubInput = kind.prefill(from: current) ?? ""
            if let current, current.scheme?.hasPrefix("http") == true, githubInput.isEmpty { feedInput = current.absoluteString }
            fieldFocused = true
        }
        .onChange(of: source) {
            error = nil
            fieldFocused = true
        }
        .onChange(of: kind) { old, new in
            error = nil
            let current = store.selectedRecord?.url
            if githubInput.isEmpty || githubInput == old.prefill(from: current) {
                githubInput = new.prefill(from: current) ?? ""
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Live Folder")
                    .font(.system(size: 20, weight: .semibold))
                Text("Follows a feed and shows new posts in your sidebar. It refreshes every 15 minutes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            IconButton(symbol: "xmark", help: "Cancel (Esc)", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var githubForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(GitHubFeed.allCases) { option in
                    let selected = kind == option
                    VStack(spacing: 5) {
                        Image(systemName: option.symbol).font(.system(size: 14, weight: .medium))
                        Text(option.title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 4)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.primary.opacity(selected ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { kind = option }
                }
            }
            HStack(spacing: 0) {
                Text("github.com/").foregroundStyle(.tertiary)
                field(kind.placeholder, text: $githubInput)
            }
            .inputStyle()
            Text(kind.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rssForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("https://example.com/feed.xml", text: $feedInput)
                .inputStyle()
            Text("Paste an RSS or Atom feed, or any website address and Barc will find its feed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .focused($fieldFocused)
            .onSubmit(submit)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: submit) {
                HStack(spacing: 6) {
                    if loading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(loading ? "Loading Feed…" : "Add Live Folder")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(.primary.opacity(canSubmit ? 1 : 0.4), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !loading && !(source == .github ? githubInput : feedInput).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let url: URL
        var name: String?
        switch source {
        case .github:
            guard let feed = kind.feed(for: githubInput) else {
                error = "Enter a GitHub \(kind.placeholder), like \(kind.example)."
                return
            }
            url = feed.url
            name = feed.name
        case .rss:
            let text = feedInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "feed://", with: "https://")
            guard let parsed = URLInput.looksLikeHost(text) && !text.contains("://") ? URL(string: "https://\(text)") : URL(string: text),
                  parsed.scheme?.hasPrefix("http") == true else {
                error = "Enter a feed or website address."
                return
            }
            url = parsed
        }
        loading = true
        error = nil
        Task {
            do {
                let result = try await FeedLoader.load(url)
                let title = result.document.title?.trimmingCharacters(in: .whitespaces)
                store.addLiveFolder(name: name ?? (title?.isEmpty == false ? title! : result.url.host() ?? "Feed"), feedURL: result.url, document: result.document)
                store.creatingLiveFolder = false
                store.showToast("Live folder added", symbol: "dot.radiowaves.up.forward")
            } catch {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func cancel() {
        store.creatingLiveFolder = false
        store.focusWebView()
    }
}

private extension View {
    func inputStyle() -> some View {
        font(.system(size: 13))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

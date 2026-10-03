import XCTest
@testable import Barc

@MainActor
final class LiveFolderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appending(path: "barc-tests-\(UUID().uuidString)")
        setenv("BARC_DATA_DIR", tempDir.path(), 1)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        unsetenv("BARC_DATA_DIR")
    }

    private let atom = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
      <id>tag:github.com,2008:https://github.com/apple/swift/releases</id>
      <link type="text/html" rel="alternate" href="https://github.com/apple/swift/releases"/>
      <link type="application/atom+xml" rel="self" href="https://github.com/apple/swift/releases.atom"/>
      <title>Release notes from swift</title>
      <updated>2026-09-20T10:00:00Z</updated>
      <entry>
        <id>tag:github.com,2008:Repository/44838949/swift-6.3</id>
        <updated>2026-09-20T10:00:00Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/apple/swift/releases/tag/swift-6.3"/>
        <title>Swift 6.3
        Release</title>
        <content type="html">&lt;p&gt;Notes&lt;/p&gt;</content>
        <author><name>swift-ci</name></author>
      </entry>
      <entry>
        <id>tag:github.com,2008:Repository/44838949/swift-6.2</id>
        <updated>2026-06-01T08:30:00.000Z</updated>
        <link rel="alternate" type="text/html" href="/apple/swift/releases/tag/swift-6.2"/>
        <title>Swift 6.2</title>
      </entry>
    </feed>
    """

    private let rss = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel>
        <title>Example Blog</title>
        <link>https://example.com/</link>
        <item>
          <title><![CDATA[Hello & welcome]]></title>
          <link>https://example.com/hello</link>
          <guid isPermaLink="false">post-1</guid>
          <pubDate>Mon, 21 Sep 2026 09:00:00 GMT</pubDate>
        </item>
        <item>
          <title>Second</title>
          <link>/second</link>
          <dc:date>2026-09-22T09:00:00Z</dc:date>
        </item>
        <item>
          <title>No link</title>
        </item>
      </channel>
    </rss>
    """

    func testParsesGitHubAtom() throws {
        let feedURL = URL(string: "https://github.com/apple/swift/releases.atom")!
        let document = try XCTUnwrap(FeedParser.parse(Data(atom.utf8), baseURL: feedURL))
        XCTAssertEqual(document.title, "Release notes from swift")
        XCTAssertEqual(document.siteURL, URL(string: "https://github.com/apple/swift/releases"))
        XCTAssertEqual(document.items.map(\.title), ["Swift 6.3 Release", "Swift 6.2"])
        XCTAssertEqual(document.items[0].id, "tag:github.com,2008:Repository/44838949/swift-6.3")
        XCTAssertEqual(document.items[1].url, URL(string: "https://github.com/apple/swift/releases/tag/swift-6.2"))
        XCTAssertEqual(document.items[0].date, ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))
        XCTAssertNotNil(document.items[1].date)
        XCTAssertEqual(FeedParser.date("2026-09-20 10:00:00 UTC"), document.items[0].date)
    }

    func testParsesRSS() throws {
        let document = try XCTUnwrap(FeedParser.parse(Data(rss.utf8), baseURL: URL(string: "https://example.com/feed.xml")!))
        XCTAssertEqual(document.title, "Example Blog")
        XCTAssertEqual(document.siteURL, URL(string: "https://example.com/"))
        XCTAssertEqual(document.items.map(\.title), ["Hello & welcome", "Second"])
        XCTAssertEqual(document.items[0].id, "post-1")
        XCTAssertEqual(document.items[1].id, "https://example.com/second")
        XCTAssertNotNil(document.items[0].date)
        XCTAssertNotNil(document.items[1].date)
    }

    func testRejectsHTMLAndDiscoversFeed() throws {
        let html = """
        <!doctype html><html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="Posts" href="/feed.xml?a=1&amp;b=2">
        </head><body></body></html>
        """
        let page = URL(string: "https://example.com/blog/")!
        XCTAssertNil(FeedParser.parse(Data(html.utf8), baseURL: page))
        XCTAssertEqual(FeedParser.discover(in: html, baseURL: page), URL(string: "https://example.com/feed.xml?a=1&b=2"))
        XCTAssertNil(FeedParser.discover(in: "<link rel=\"icon\" href=\"/x.png\">", baseURL: page))
    }

    func testGitHubFeedURLs() {
        XCTAssertEqual(GitHubFeed.releases.feed(for: "apple/swift")?.url.absoluteString, "https://github.com/apple/swift/releases.atom")
        XCTAssertEqual(GitHubFeed.releases.feed(for: "apple/swift")?.name, "swift Releases")
        XCTAssertEqual(GitHubFeed.tags.feed(for: "https://github.com/apple/swift.git")?.url.absoluteString, "https://github.com/apple/swift/tags.atom")
        XCTAssertEqual(GitHubFeed.commits.feed(for: "github.com/apple/swift")?.url.absoluteString, "https://github.com/apple/swift/commits.atom")
        XCTAssertEqual(
            GitHubFeed.commits.feed(for: "https://github.com/apple/swift/tree/release/6.3")?.url.absoluteString,
            "https://github.com/apple/swift/commits/release/6.3.atom"
        )
        XCTAssertEqual(GitHubFeed.activity.feed(for: "torvalds")?.url.absoluteString, "https://github.com/torvalds.atom")
        XCTAssertNil(GitHubFeed.pullRequests.feed(for: "apple/swift"), "Pull requests follow a user, not a repo")
        XCTAssertEqual(GitHubFeed.pullRequests.feed(for: "https://github.com/torvalds")?.name, "torvalds Pull Requests")
        let search = URLComponents(url: GitHubFeed.pullRequests.feed(for: "torvalds")!.url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(search.path, "/search/issues")
        XCTAssertEqual(search.queryItems?.first { $0.name == "q" }?.value, "is:pr is:open author:torvalds")
        XCTAssertNil(GitHubFeed.releases.feed(for: "apple"))
        XCTAssertNil(GitHubFeed.releases.feed(for: "bad name/repo"))
        let page = URL(string: "https://github.com/apple/swift/pull/1")
        XCTAssertEqual(GitHubFeed.releases.prefill(from: page), "apple/swift")
        XCTAssertEqual(GitHubFeed.pullRequests.prefill(from: page), "apple")
        XCTAssertNil(GitHubFeed.releases.prefill(from: URL(string: "https://github.com/torvalds")))
        XCTAssertNil(GitHubFeed.pullRequests.prefill(from: URL(string: "https://github.com/notifications")))
        XCTAssertNil(GitHubFeed.pullRequests.prefill(from: URL(string: "https://example.com/apple/swift")))
    }

    func testParsesGitHubPulls() throws {
        let searchJSON = #"{"total_count":1,"items":[{"id":12,"title":"Add docs","html_url":"https://github.com/o/r/pull/9","updated_at":"2026-09-26T12:00:00Z"}]}"#
        let search = try XCTUnwrap(GitHubFeed.parsePulls(Data(searchJSON.utf8), apiURL: URL(string: "https://api.github.com/search/issues?q=x")!))
        XCTAssertEqual(search.siteURL, URL(string: "https://github.com/pulls"))
        XCTAssertEqual(search.items, [LiveItem(id: "12", title: "Add docs", url: URL(string: "https://github.com/o/r/pull/9")!, date: ISO8601DateFormatter().date(from: "2026-09-26T12:00:00Z"))])
        XCTAssertNil(GitHubFeed.parsePulls(Data(#"{"message":"Not Found"}"#.utf8), apiURL: URL(string: "https://api.github.com/search/issues?q=x")!))
    }

    func testApplyLimitsItemsAndKeepsOpenTabs() {
        func item(_ id: String) -> LiveItem { LiveItem(id: id, title: id, url: URL(string: "https://example.com/\(id)")!) }
        var feed = LiveFeed(url: URL(string: "https://example.com/feed")!)
        feed.apply(FeedDocument(items: (1...8).map { item("\($0)") }))
        XCTAssertEqual(feed.items.map(\.id), ["1", "2", "3", "4", "5"])

        let tab = UUID()
        feed.items[4].tab = tab
        feed.apply(FeedDocument(items: (0...8).reversed().map { item("\($0 + 10)") }))
        XCTAssertEqual(feed.items.map(\.id), ["18", "17", "16", "15", "14", "5"])
        XCTAssertEqual(feed.items.last?.tab, tab)
        XCTAssertEqual(feed.visibleItems.count, 6)
    }

    func testApplyKeepsReadState() {
        func item(_ id: String) -> LiveItem { LiveItem(id: id, title: id, url: URL(string: "https://example.com/\(id)")!) }
        var feed = LiveFeed(url: URL(string: "https://example.com/feed")!)
        feed.apply(FeedDocument(items: [item("a"), item("b"), item("a")]))
        XCTAssertEqual(feed.items.map(\.id), ["a", "b"])
        XCTAssertEqual(feed.unreadCount, 0, "Items from the first load start out read")

        feed.items[1].isRead = false
        feed.error = "offline"
        feed.apply(FeedDocument(items: [item("c"), item("a"), item("b")]))
        XCTAssertEqual(feed.items.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(feed.items.map(\.isRead), [false, true, false])
        XCTAssertNil(feed.error)
    }

    func testLiveFolderTabsStayInFolder() throws {
        let store = BrowserStore()
        let url = URL(string: "https://github.com/apple/swift/releases.atom")!
        let document = try XCTUnwrap(FeedParser.parse(Data(atom.utf8), baseURL: url))
        let folderID = store.addLiveFolder(name: "swift Releases", feedURL: url, document: document)

        XCTAssertEqual(store.liveFeed(folderID)?.items.count, 2)
        XCTAssertFalse(store.folders.contains { $0.id == folderID })

        let tab = store.newTab(URL(string: "https://example.com")!)
        store.move(.tab(tab), to: .folder(space: store.currentSpace.id, folder: folderID), index: 0)
        XCTAssertEqual(store.location(of: tab), .today(space: store.currentSpace.id))

        let item = try XCTUnwrap(store.liveFeed(folderID)?.items.first)
        store.setLiveItemRead(item.id, in: folderID, read: false)
        XCTAssertEqual(store.liveFeed(folderID)?.unreadCount, 1)
        let todayBefore = store.currentSpace.today
        store.openLiveItem(item, folder: folderID)
        XCTAssertEqual(store.liveFeed(folderID)?.unreadCount, 0)
        XCTAssertEqual(store.selectedRecord?.url, item.url)
        let opened = try XCTUnwrap(store.liveFeed(folderID)?.items.first?.tab)
        XCTAssertEqual(store.location(of: opened), .folder(space: store.currentSpace.id, folder: folderID))
        XCTAssertEqual(store.currentSpace.today, todayBefore, "Live folder posts open inside the folder, not in Today")

        store.openLiveItem(item, folder: folderID)
        XCTAssertEqual(store.ids(in: .folder(space: store.currentSpace.id, folder: folderID)), [opened], "Reopening selects the same tab")

        store.saveNow()
        let reloaded = BrowserStore()
        XCTAssertEqual(reloaded.liveFeed(folderID), store.liveFeed(folderID))

        store.close(opened)
        XCTAssertNil(store.record(opened))
        XCTAssertNil(store.location(of: opened))
        XCTAssertNil(store.liveFeed(folderID)?.items.first?.tab)
        XCTAssertTrue(store.ids(in: .folder(space: store.currentSpace.id, folder: folderID)).isEmpty)

        store.openLiveItem(item, folder: folderID)
        let reopened = try XCTUnwrap(store.liveFeed(folderID)?.items.first?.tab)
        let pinnedBefore = store.currentSpace.pinned.count
        store.deleteFolder(folderID)
        XCTAssertNil(store.record(reopened), "Deleting a live folder closes its tabs instead of pinning them")
        XCTAssertEqual(store.currentSpace.pinned.count, pinnedBefore - 1)
    }

    func testLegacyFolderDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"Old","isExpanded":true,"tabs":[]}"#
        let folder = try JSONDecoder().decode(Folder.self, from: Data(json.utf8))
        XCTAssertEqual(folder.name, "Old")
        XCTAssertNil(folder.live)
    }
}

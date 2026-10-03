import XCTest
@testable import Barc

@MainActor
final class PinnedTabTests: XCTestCase {
    private var tempDir: URL!
    private let home = URL(string: "about:blank#pinned")!
    private let visited = URL(string: "about:blank#visited")!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appending(path: "barc-pinned-tests-\(UUID().uuidString)")
        setenv("BARC_DATA_DIR", tempDir.path(), 1)
        try FileManager.default.createDirectory(at: BrowserStore.supportDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        unsetenv("BARC_DATA_DIR")
    }

    private func pinnedTab(in store: BrowserStore) -> UUID {
        let id = store.newTab(home)
        store.session(id).onUpdate?(home, "Pinned page")
        store.togglePin(id)
        store.session(id).onUpdate?(visited, "Visited page")
        return id
    }

    func testClosingAndReopeningReturnsToPinnedPage() {
        let store = BrowserStore()
        let id = pinnedTab(in: store)
        XCTAssertEqual(store.record(id)?.displayTitle, "Pinned page")
        XCTAssertEqual(store.record(id)?.url, visited)

        store.close(id)
        XCTAssertTrue(store.isPinned(id))
        XCTAssertFalse(store.isLive(id))
        XCTAssertEqual(store.record(id)?.url, home)
        XCTAssertEqual(store.session(id).currentURL, home)
        store.select(id)
        XCTAssertEqual(store.selectedTabID, id)
        XCTAssertEqual(store.session(id).currentURL, home)
    }

    func testRestoringAppReturnsPinnedTabsToHome() {
        let store = BrowserStore()
        let id = pinnedTab(in: store)
        let today = store.newTab(visited)
        store.saveNow()

        let restored = BrowserStore()
        XCTAssertEqual(restored.record(id)?.url, home)
        XCTAssertEqual(restored.record(id)?.displayTitle, "Pinned page")
        XCTAssertEqual(restored.session(id).currentURL, home)
        XCTAssertEqual(restored.record(today)?.url, visited)
    }

    func testMovingToFavoritesKeepsOriginalPinnedPage() {
        let store = BrowserStore()
        let id = pinnedTab(in: store)
        store.toggleFavorite(id)
        store.close(id)
        XCTAssertTrue(store.isFavorite(id))
        XCTAssertEqual(store.record(id)?.homeURL, home)
        XCTAssertEqual(store.session(id).currentURL, home)
    }

    func testUnpinningKeepsCurrentPageAndClearsPinnedLabel() {
        let store = BrowserStore()
        let id = pinnedTab(in: store)
        store.togglePin(id)
        XCTAssertNil(store.record(id)?.homeURL)
        XCTAssertNil(store.record(id)?.homeTitle)
        XCTAssertEqual(store.record(id)?.url, visited)
        XCTAssertEqual(store.record(id)?.displayTitle, "Visited page")
    }
}

import WebKit
import XCTest
@testable import Barc

@MainActor
final class SpaceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appending(path: "barc-tests-\(UUID().uuidString)")
        setenv("BARC_DATA_DIR", tempDir.path(), 1)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        unsetenv("BARC_DATA_DIR")
    }

    func testAddSpaceUsesDraft() {
        let store = BrowserStore()
        var draft = store.suggestedSpace
        draft.name = "  Work  "
        draft.symbol = "briefcase.fill"
        draft.theme = ThemePreset.midnight.theme
        draft.sharesData = false
        let id = store.addSpace(draft)

        XCTAssertEqual(store.currentSpace.id, id)
        XCTAssertEqual(store.currentSpace.name, "Work")
        XCTAssertEqual(store.currentSpace.symbol, "briefcase.fill")
        XCTAssertEqual(store.currentSpace.theme, ThemePreset.midnight.theme)
        XCTAssertFalse(store.currentSpace.sharesData)
        XCTAssertTrue(store.currentSpace.favorites.isEmpty)
        XCTAssertTrue(store.currentSpace.pinned.isEmpty)
    }

    func testFavoritesArePerSpace() {
        let store = BrowserStore()
        let first = store.currentSpace.id
        let seeded = store.currentSpace.favorites
        XCTAssertFalse(seeded.isEmpty)

        store.addSpace()
        let second = store.currentSpace.id
        XCTAssertTrue(store.currentSpace.favorites.isEmpty)
        let tab = store.newTab(URL(string: "https://example.com")!)
        store.toggleFavorite(tab)

        XCTAssertEqual(store.location(of: tab), .favorites(space: second))
        XCTAssertEqual(store.currentSpace.favorites, [tab])
        XCTAssertEqual(store.library.spaces.first { $0.id == first }?.favorites, seeded)
        XCTAssertFalse(store.navigableTabs.contains(seeded[0]))

        store.select(seeded[0])
        XCTAssertEqual(store.currentSpace.id, first)
    }

    func testLegacyGlobalFavoritesMigrateToSelectedSpace() throws {
        let fav = UUID(), a = UUID(), b = UUID()
        let json = """
        {"favorites":["\(fav)"],"selectedSpace":"\(b)","tabs":[],
         "spaces":[{"id":"\(a)","name":"A","symbol":"sparkles","theme":"ocean","pinned":[],"today":[]},
                   {"id":"\(b)","name":"B","symbol":"sparkles","theme":"mint","pinned":[],"today":[]}]}
        """
        let library = try JSONDecoder().decode(Library.self, from: Data(json.utf8))
        XCTAssertEqual(library.spaces[0].favorites, [])
        XCTAssertEqual(library.spaces[1].favorites, [fav])
        XCTAssertTrue(library.spaces.allSatisfy(\.sharesData))
    }

    func testIsolatedSpaceGetsOwnDataStore() {
        let store = BrowserStore()
        let shared = store.newTab(URL(string: "https://example.com")!, background: true)
        XCTAssertTrue(store.session(shared).dataStore === WKWebsiteDataStore.default())

        var draft = store.suggestedSpace
        draft.sharesData = false
        let isolated = store.addSpace(draft)
        let tab = store.newTab(URL(string: "https://example.org")!)
        XCTAssertEqual(store.session(tab).dataStore.identifier, isolated)

        store.move(.tab(tab), to: .today(space: store.library.spaces[0].id), index: 0)
        XCTAssertTrue(store.session(tab).dataStore === WKWebsiteDataStore.default())

        store.move(.tab(tab), to: .today(space: isolated), index: 0)
        store.setSharesData(isolated, true)
        XCTAssertTrue(store.session(tab).dataStore === WKWebsiteDataStore.default())
    }
}

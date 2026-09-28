import XCTest
@testable import Barc

@MainActor
final class MoveTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appending(path: "barc-tests-\(UUID().uuidString)")
        setenv("BARC_DATA_DIR", tempDir.path(), 1)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        unsetenv("BARC_DATA_DIR")
    }

    private func makeStore() -> BrowserStore {
        BrowserStore()
    }

    func testDragTabIntoFolderKeepsTab() {
        let store = makeStore()
        let folder = store.newFolder()
        let url = URL(string: "https://example.com")!
        let id = store.newTab(url)

        let payload = [DragPayload.tab(id)]
        let dropped = store.handleDrop(payload, to: .folder(space: store.currentSpace.id, folder: folder), index: Int.max)
        XCTAssertTrue(dropped)

        guard case .folder(_, let folderID)? = store.location(of: id) else {
            return XCTFail("tab vanished after folder drop; location = \(String(describing: store.location(of: id)))")
        }
        XCTAssertEqual(folderID, folder)
        XCTAssertTrue(store.folders.first { $0.id == folder }?.tabs.contains(id) ?? false)
        XCTAssertNotNil(store.record(id))
    }

    func testDragPinnedTabBetweenSpacesAndBack() {
        let store = makeStore()
        store.addSpace()
        let url = URL(string: "https://example.org")!
        let id = store.newTab(url)
        store.togglePin(id)
        XCTAssertTrue(store.isPinned(id))

        let other = store.library.spaces.first { $0.id != store.currentSpace.id }!
        store.move(.tab(id), to: .pinned(space: other.id), index: Int.max)
        XCTAssertNotNil(store.record(id))

        store.move(.tab(id), to: .folder(space: store.currentSpace.id, folder: store.newFolder()), index: Int.max)
        XCTAssertNotNil(store.record(id), "tab disappeared when moving into folder")
    }

    func testFolderDeletionKeepsTabs() {
        let store = makeStore()
        let folder = store.newFolder()
        let id = store.newTab(URL(string: "https://example.net")!)
        store.handleDrop([DragPayload.tab(id)], to: .folder(space: store.currentSpace.id, folder: folder), index: Int.max)
        store.deleteFolder(folder)
        XCTAssertNotNil(store.record(id))
    }

    func testCloseSelectedPicksNeighbor() {
        let store = makeStore()
        let a = store.newTab(URL(string: "https://a.com")!)
        let b = store.newTab(URL(string: "https://b.com")!)
        let c = store.newTab(URL(string: "https://c.com")!)
        store.select(b)
        store.close(b)
        XCTAssertNotEqual(store.selectedTabID, b)
        XCTAssertTrue([a, c].contains(store.selectedTabID ?? UUID()))
    }

    func testLiveReorderInsideFolder() {
        let store = makeStore()
        let space = store.currentSpace.id
        let folder = store.newFolder()
        let dest = Destination.folder(space: space, folder: folder)
        let a = store.newTab(URL(string: "https://a.com")!, background: true, at: dest, index: Int.max)
        let b = store.newTab(URL(string: "https://b.com")!, background: true, at: dest, index: Int.max)
        let c = store.newTab(URL(string: "https://c.com")!, background: true, at: dest, index: Int.max)
        XCTAssertEqual(store.ids(in: dest), [a, b, c])

        store.beginDrag(tab: a)
        XCTAssertTrue(store.liveReorder(onto: b, in: dest))
        XCTAssertEqual(store.ids(in: dest), [b, a, c])
        XCTAssertTrue(store.liveReorder(onto: c, in: dest))
        XCTAssertEqual(store.ids(in: dest), [b, c, a])
        XCTAssertTrue(store.liveReorder(onto: b, in: dest))
        XCTAssertEqual(store.ids(in: dest), [a, b, c])
        XCTAssertFalse(store.liveReorder(onto: a, in: dest))
        store.endDrag()
    }

    func testLiveReorderFavoritesAndFolders() {
        let store = makeStore()
        let space = store.currentSpace.id
        let favorites = store.currentSpace.favorites
        store.beginDrag(tab: favorites[0])
        store.liveReorder(onto: favorites[2], in: .favorites(space: space))
        XCTAssertEqual(store.currentSpace.favorites, [favorites[1], favorites[2], favorites[0], favorites[3]])
        store.endDrag()

        let first = store.newFolder()
        let second = store.newFolder()
        XCTAssertEqual(store.ids(in: .pinned(space: space)), [second, first])
        store.beginDrag(folder: second)
        store.liveReorder(onto: first, in: .pinned(space: space))
        XCTAssertEqual(store.ids(in: .pinned(space: space)), [first, second])
        store.endDrag()
    }

    func testLiveReorderAcrossContainers() {
        let store = makeStore()
        let space = store.currentSpace.id
        let folder = store.newFolder()
        let dest = Destination.folder(space: space, folder: folder)
        let inFolder = store.newTab(URL(string: "https://a.com")!, background: true, at: dest, index: 0)
        let loose = store.newTab(URL(string: "https://b.com")!, background: true)
        store.beginDrag(tab: loose)
        store.liveReorder(onto: inFolder, in: dest)
        XCTAssertEqual(store.ids(in: dest), [loose, inFolder])
        XCTAssertFalse(store.ids(in: .today(space: space)).contains(loose))
        store.endDrag()
    }
}

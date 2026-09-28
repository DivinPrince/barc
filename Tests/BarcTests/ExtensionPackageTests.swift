import XCTest
@testable import Barc

final class ExtensionPackageTests: XCTestCase {
    func testWebStoreIDParsing() {
        let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        XCTAssertEqual(ExtensionPackage.webStoreID(from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)"), id)
        XCTAssertEqual(ExtensionPackage.webStoreID(from: "https://chromewebstore.google.com/detail/\(id)?hl=en"), id)
        XCTAssertEqual(ExtensionPackage.webStoreID(from: "https://chrome.google.com/webstore/detail/x/\(id)"), id)
        XCTAssertEqual(ExtensionPackage.webStoreID(from: "  \(id.uppercased()) "), id)
        XCTAssertNil(ExtensionPackage.webStoreID(from: "https://example.com/\(id)"))
        XCTAssertNil(ExtensionPackage.webStoreID(from: "not an id"))
    }

    func testCRX3HeaderIsStripped() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0xAA, 0xBB])
        let header = Data(repeating: 7, count: 10)
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [3, 0, 0, 0])
        crx.append(contentsOf: [UInt8(header.count), 0, 0, 0])
        crx.append(header)
        crx.append(zip)
        XCTAssertEqual(try ExtensionPackage.zipData(fromCRX: crx), zip)
    }

    func testCRX2HeaderIsStripped() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [2, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0])
        crx.append(contentsOf: [1, 2, 3, 4, 5])
        crx.append(zip)
        XCTAssertEqual(try ExtensionPackage.zipData(fromCRX: crx), zip)
    }

    func testPlainZipPassesThroughAndGarbageFails() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(try ExtensionPackage.zipData(fromCRX: zip), zip)
        XCTAssertThrowsError(try ExtensionPackage.zipData(fromCRX: Data("hello world, not a crx".utf8)))
    }
}

final class ChromeCompatibilityTests: XCTestCase {
    func testIdleShimIsAddedOnceAndKeepsStrictMode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "barc-idle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "(()=>{})();".write(to: root.appending(path: "plain.js"), atomically: true, encoding: .utf8)
        try "\n'use strict'\nfoo();".write(to: root.appending(path: "nested/strict.mjs"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appending(path: "data.json"), atomically: true, encoding: .utf8)

        ChromeCompatibility.addIdleShim(in: root)
        ChromeCompatibility.addIdleShim(in: root)

        let plain = try String(contentsOf: root.appending(path: "plain.js"), encoding: .utf8)
        let strict = try String(contentsOf: root.appending(path: "nested/strict.mjs"), encoding: .utf8)
        XCTAssertEqual(plain, ChromeCompatibility.idleShim + "(()=>{})();")
        XCTAssertEqual(strict, "\n'use strict';" + ChromeCompatibility.idleShim + "\nfoo();")
        XCTAssertEqual(try String(contentsOf: root.appending(path: "data.json"), encoding: .utf8), "{}")
    }
}

final class InstalledExtensionTests: XCTestCase {
    func testLegacyRegistryDecodesWithPinnedDefault() throws {
        let json = #"[{"id":"ddkjiahejlhfcafbddmgiahcphecmpfh","enabled":true,"webStoreID":"ddkjiahejlhfcafbddmgiahcphecmpfh"}]"#
        let list = try JSONDecoder().decode([InstalledExtension].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.pinned, false)
        XCTAssertEqual(list.first?.enabled, true)
    }

    func testPinnedRoundTrips() throws {
        let item = InstalledExtension(id: "abc", pinned: true)
        let decoded = try JSONDecoder().decode(InstalledExtension.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
    }
}

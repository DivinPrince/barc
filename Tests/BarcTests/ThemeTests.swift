import XCTest
@testable import Barc

final class ThemeTests: XCTestCase {
    func testLegacyThemeStringMigratesToPreset() throws {
        let json = #"{"name":"Personal","symbol":"sparkles","theme":"midnight","pinned":[],"today":[],"id":"1835C62B-6D40-4DBD-94A7-5DCDFD5B57DD"}"#
        let space = try JSONDecoder().decode(Space.self, from: Data(json.utf8))
        XCTAssertEqual(space.theme, ThemePreset.midnight.theme)
        XCTAssertEqual(space.theme.mode, .dark)
    }

    func testRoundTrip() throws {
        var theme = ThemePreset.aurora.theme
        theme.grain = 0.375
        let decoded = try JSONDecoder().decode(SpaceTheme.self, from: JSONEncoder().encode(theme))
        XCTAssertEqual(decoded, theme)
    }

    func testPrimaryDragKeepsHarmony() {
        var theme = SpaceTheme(dots: [.init(angle: 10, radius: 0.5), .init(angle: 0, radius: 0), .init(angle: 0, radius: 0)], harmony: .triadic)
        theme.dots[0] = ThemeDot(angle: 300, radius: 0.8)
        theme.applyHarmony()
        XCTAssertEqual(theme.dots[1].angle, 60, accuracy: 0.001)
        XCTAssertEqual(theme.dots[2].angle, 180, accuracy: 0.001)
        XCTAssertEqual(theme.dots[2].radius, 0.8, accuracy: 0.001)
    }

    func testAddAndRemoveDots() {
        var theme = SpaceTheme(dots: [.init(angle: 200, radius: 0.6)])
        theme.addDot()
        XCTAssertEqual(theme.dots.count, 2)
        XCTAssertEqual(theme.dots[1].angle, 245, accuracy: 0.001)
        theme.addDot()
        theme.addDot()
        XCTAssertEqual(theme.dots.count, SpaceTheme.maxDots)
        theme.removeDot()
        theme.removeDot()
        theme.removeDot()
        XCTAssertEqual(theme.dots.count, 1)
    }

    func testModeDrivesDarkness() {
        var theme = ThemePreset.ocean.theme
        theme.mode = .auto
        XCTAssertTrue(theme.isDark(systemDark: true))
        XCTAssertFalse(theme.isDark(systemDark: false))
        theme.mode = .dark
        XCTAssertTrue(theme.palette(systemDark: false).isDark)
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import Barc

@MainActor
final class FaviconGlowTests: XCTestCase {
    func testTwoToneIconProducesLeftAndRightColors() throws {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(srgbRed: 0.1, green: 0.4, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 16, height: 32).fill()
            NSColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1).setFill()
            NSRect(x: 16, y: 0, width: 16, height: 32).fill()
            return true
        }
        let colors = FaviconStore.dominantColors(image).map { NSColor($0).usingColorSpace(.sRGB)! }
        XCTAssertEqual(colors.count, 2)
        XCTAssertGreaterThan(colors[0].blueComponent, colors[0].redComponent)
        XCTAssertGreaterThan(colors[1].redComponent, colors[1].blueComponent)
    }

    func testMonochromeIconFallsBackToNeutral() {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
        XCTAssertEqual(FaviconStore.dominantColors(image).count, 2)
    }
}

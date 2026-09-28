import AppKit
import SwiftUI

struct ThemeDot: Codable, Equatable {
    var angle: Double
    var radius: Double
}

enum ThemeMode: String, Codable, CaseIterable {
    case light, dark, auto

    var symbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .auto: "circle.lefthalf.filled"
        }
    }

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .auto: "Match System"
        }
    }
}

enum Harmony: String, Codable, CaseIterable {
    case analogous, complementary, triadic, split, floating

    var label: String {
        switch self {
        case .analogous: "Analogous"
        case .complementary: "Complementary"
        case .triadic: "Triadic"
        case .split: "Split"
        case .floating: "Free"
        }
    }

    func offsets(for count: Int) -> [Double]? {
        switch (self, count) {
        case (.analogous, 2): [45]
        case (.analogous, 3): [-45, 45]
        case (.complementary, 2): [180]
        case (.triadic, 3): [120, 240]
        case (.split, 3): [150, 210]
        default: nil
        }
    }

    static func options(for count: Int) -> [Harmony] {
        switch count {
        case 2: [.analogous, .complementary, .floating]
        case 3: [.analogous, .triadic, .split, .floating]
        default: []
        }
    }
}

struct Palette: Equatable {
    let colors: [Color]
    let accent: Color
    let isDark: Bool
    let grain: Double
}

struct SpaceTheme: Codable, Equatable {
    var dots: [ThemeDot]
    var harmony: Harmony = .analogous
    var intensity: Double = 0.6
    var grain: Double = 0
    var mode: ThemeMode = .auto

    static let maxDots = 3

    init(dots: [ThemeDot], harmony: Harmony = .analogous, intensity: Double = 0.6, grain: Double = 0, mode: ThemeMode = .auto) {
        self.dots = dots
        self.harmony = harmony
        self.intensity = intensity
        self.grain = grain
        self.mode = mode
        applyHarmony()
    }

    private enum CodingKeys: String, CodingKey {
        case dots, harmony, intensity, grain, mode
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self = ThemePreset(rawValue: legacy)?.theme ?? ThemePreset.lavender.theme
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dots = try container.decode([ThemeDot].self, forKey: .dots)
        harmony = try container.decodeIfPresent(Harmony.self, forKey: .harmony) ?? .floating
        intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.6
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        mode = try container.decodeIfPresent(ThemeMode.self, forKey: .mode) ?? .auto
    }

    mutating func applyHarmony() {
        guard let primary = dots.first, let offsets = harmony.offsets(for: dots.count) else { return }
        for (index, offset) in offsets.enumerated() {
            dots[index + 1] = ThemeDot(angle: (primary.angle + offset).wrappedDegrees, radius: primary.radius)
        }
    }

    mutating func addDot() {
        guard dots.count < Self.maxDots, let primary = dots.first else { return }
        let freeAngle = harmony == .floating ? primary.angle + 180 : primary.angle
        dots.append(ThemeDot(angle: freeAngle.wrappedDegrees, radius: primary.radius))
        if harmony != .floating { harmony = .analogous }
        applyHarmony()
    }

    mutating func removeDot() {
        guard dots.count > 1 else { return }
        dots.removeLast()
        if harmony != .floating { harmony = .analogous }
        applyHarmony()
    }

    func isDark(systemDark: Bool) -> Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .auto: systemDark
        }
    }

    func palette(systemDark: Bool) -> Palette {
        let dark = isDark(systemDark: systemDark)
        let colors = dots.map { Color(nsColor: Self.color(for: $0, intensity: intensity, dark: dark)) }
        let primary = dots.first ?? ThemeDot(angle: 260, radius: 0.5)
        let accent = NSColor(
            hue: primary.angle / 360,
            saturation: max(0.35, min(0.85, primary.radius * 0.95)),
            brightness: dark ? 0.82 : 0.68,
            alpha: 1
        )
        return Palette(colors: colors, accent: Color(nsColor: accent), isDark: dark, grain: grain)
    }

    static func color(for dot: ThemeDot, intensity: Double, dark: Bool) -> NSColor {
        let hue = dot.angle / 360
        let r = min(1, max(0, dot.radius))
        if dark {
            return NSColor(hue: hue, saturation: r * (0.28 + 0.55 * intensity), brightness: 0.13 + 0.3 * intensity * (0.55 + 0.45 * r), alpha: 1)
        }
        return NSColor(hue: hue, saturation: r * (0.1 + 0.62 * intensity), brightness: 0.99 - 0.13 * intensity * r, alpha: 1)
    }

    static func vivid(angle: Double, radius: Double, dark: Bool) -> Color {
        Color(nsColor: NSColor(hue: angle / 360, saturation: min(1, radius) * 0.85, brightness: dark ? 0.78 : 0.9, alpha: 1))
    }
}

enum ThemePreset: String, CaseIterable, Identifiable {
    case lavender, ocean, mint, peach, rose, sand, aurora, sunset, graphite, midnight, forest, plum

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var theme: SpaceTheme {
        switch self {
        case .lavender: SpaceTheme(dots: [.init(angle: 258, radius: 0.62), .init(angle: 0, radius: 0)], intensity: 0.65, mode: .light)
        case .ocean: SpaceTheme(dots: [.init(angle: 212, radius: 0.62), .init(angle: 0, radius: 0)], intensity: 0.6, mode: .light)
        case .mint: SpaceTheme(dots: [.init(angle: 158, radius: 0.55), .init(angle: 0, radius: 0)], intensity: 0.55, mode: .light)
        case .peach: SpaceTheme(dots: [.init(angle: 18, radius: 0.6), .init(angle: 0, radius: 0)], intensity: 0.6, mode: .light)
        case .rose: SpaceTheme(dots: [.init(angle: 332, radius: 0.58)], intensity: 0.6, mode: .light)
        case .sand: SpaceTheme(dots: [.init(angle: 40, radius: 0.35)], intensity: 0.5, grain: 0.25, mode: .light)
        case .aurora: SpaceTheme(dots: [.init(angle: 285, radius: 0.7), .init(angle: 0, radius: 0), .init(angle: 0, radius: 0)], harmony: .triadic, intensity: 0.55, mode: .auto)
        case .sunset: SpaceTheme(dots: [.init(angle: 12, radius: 0.75), .init(angle: 0, radius: 0), .init(angle: 0, radius: 0)], harmony: .analogous, intensity: 0.65, mode: .light)
        case .graphite: SpaceTheme(dots: [.init(angle: 228, radius: 0.18)], intensity: 0.6, grain: 0.2, mode: .dark)
        case .midnight: SpaceTheme(dots: [.init(angle: 240, radius: 0.62), .init(angle: 0, radius: 0)], intensity: 0.6, mode: .dark)
        case .forest: SpaceTheme(dots: [.init(angle: 150, radius: 0.5)], intensity: 0.55, grain: 0.15, mode: .dark)
        case .plum: SpaceTheme(dots: [.init(angle: 300, radius: 0.55), .init(angle: 0, radius: 0)], harmony: .complementary, intensity: 0.5, mode: .dark)
        }
    }
}

extension Double {
    var wrappedDegrees: Double {
        let value = truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}

struct ThemeBackground: View {
    let palette: Palette
    var opacity: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let colors = palette.colors
            ZStack {
                switch colors.count {
                case 0:
                    Color.clear
                case 1:
                    LinearGradient(colors: [colors[0].opacity(0.82), colors[0]], startPoint: .top, endPoint: .bottom)
                case 2:
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                default:
                    LinearGradient(colors: [colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottom)
                    RadialGradient(
                        colors: [colors[2], colors[2].opacity(0)],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.85
                    )
                }
            }
            .opacity(opacity)
            .overlay {
                if palette.grain > 0 {
                    Image(nsImage: NoiseTexture.image)
                        .resizable(resizingMode: .tile)
                        .opacity(palette.grain * 0.55)
                        .blendMode(palette.isDark ? .screen : .multiply)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

enum NoiseTexture {
    static let image: NSImage = {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<(size * size) {
            let value = UInt8.random(in: 0...255, using: &generator)
            let alpha = UInt8.random(in: 0...70, using: &generator)
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
            pixels[i * 4 + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: size / 2, height: size / 2))
    }()
}

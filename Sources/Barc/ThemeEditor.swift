import AppKit
import SwiftUI

struct ThemeEditor: View {
    @Environment(BrowserStore.self) private var store
    let spaceID: UUID

    private var theme: SpaceTheme {
        store.library.spaces.first { $0.id == spaceID }?.theme ?? ThemePreset.lavender.theme
    }

    var body: some View {
        let theme = theme
        let palette = theme.palette(systemDark: store.systemDark)
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ModePicker(mode: theme.mode) { mode in update(animated: true) { $0.mode = mode } }
                Spacer()
                DotStepper(count: theme.dots.count) { delta in
                    update(animated: true) { delta > 0 ? $0.addDot() : $0.removeDot() }
                }
            }

            ThemePad(theme: theme, dark: palette.isDark) { change in update(animated: false, change) }

            let harmonies = Harmony.options(for: theme.dots.count)
            if !harmonies.isEmpty {
                HStack(spacing: 4) {
                    ForEach(harmonies, id: \.self) { harmony in
                        Chip(label: harmony.label, selected: theme.harmony == harmony) {
                            update(animated: true) {
                                $0.harmony = harmony
                                $0.applyHarmony()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Intensity").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    WaveSlider(value: theme.intensity, accent: palette.accent) { value in
                        update(animated: false) { $0.intensity = value }
                    }
                    .frame(height: 22)
                }
                VStack(spacing: 4) {
                    GrainDial(value: theme.grain, accent: palette.accent) { value in
                        update(animated: false) { $0.grain = value }
                    }
                    .frame(width: 46, height: 46)
                    Text("Grain").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.5)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 10), count: 8), spacing: 10) {
                ForEach(ThemePreset.allCases) { preset in
                    let presetPalette = preset.theme.palette(systemDark: store.systemDark)
                    ThemeBackground(palette: Palette(colors: presetPalette.colors, accent: presetPalette.accent, isDark: presetPalette.isDark, grain: 0))
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(theme == preset.theme ? 0.8 : 0.12), lineWidth: theme == preset.theme ? 2 : 0.5))
                        .contentShape(Circle())
                        .onTapGesture { update(animated: true) { $0 = preset.theme } }
                        .help(preset.name)
                }
            }
        }
        .padding(16)
        .frame(width: 304)
    }

    private func update(animated: Bool, _ change: (inout SpaceTheme) -> Void) {
        store.updateSpace(spaceID, animated: animated) { change(&$0.theme) }
    }
}

struct ThemePad: View {
    let theme: SpaceTheme
    let dark: Bool
    let onChange: ((inout SpaceTheme) -> Void) -> Void

    private let size: CGFloat = 272
    private let inset: CGFloat = 18

    var body: some View {
        let radius = size / 2 - inset
        let center = CGPoint(x: size / 2, y: size / 2)
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(dark ? Color(white: 0.11) : Color(white: 0.975))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)

            Canvas { context, canvasSize in
                let spacing: CGFloat = 13
                var y = spacing / 2
                while y < canvasSize.height {
                    var x = spacing / 2
                    while x < canvasSize.width {
                        let dx = x - center.x, dy = y - center.y
                        let r = min(1, sqrt(dx * dx + dy * dy) / radius)
                        let angle = angleDegrees(dy: dy, dx: dx).wrappedDegrees
                        let dotSize: CGFloat = 2.2 + r * 1.2
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)),
                            with: .color(SpaceTheme.vivid(angle: angle, radius: max(0.08, r), dark: dark).opacity(0.35 + 0.6 * r))
                        )
                        x += spacing
                    }
                    y += spacing
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .allowsHitTesting(false)

            if theme.dots.count > 1 {
                Path { path in
                    for dot in theme.dots.dropFirst() {
                        path.move(to: point(for: theme.dots[0], center: center, radius: radius))
                        path.addLine(to: point(for: dot, center: center, radius: radius))
                    }
                }
                .stroke(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
                .allowsHitTesting(false)
            }

            ForEach(Array(theme.dots.enumerated()), id: \.offset) { index, dot in
                let primary = index == 0
                Circle()
                    .fill(handleColor(dot))
                    .frame(width: primary ? 34 : 24, height: primary ? 34 : 24)
                    .overlay(Circle().strokeBorder(.white, lineWidth: primary ? 3.5 : 3))
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    .position(point(for: dot, center: center, radius: radius))
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
                            .onChanged { value in
                                let newDot = dotFor(location: value.location, center: center, radius: radius)
                                onChange { theme in
                                    theme.dots[index] = newDot
                                    if primary {
                                        theme.applyHarmony()
                                    } else {
                                        theme.harmony = .floating
                                    }
                                }
                            }
                    )
                    .zIndex(primary ? 2 : 1)
            }
        }
        .frame(width: size, height: size)
        .coordinateSpace(name: "pad")
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("pad"))
                .onChanged { value in
                    let newDot = dotFor(location: value.location, center: center, radius: radius)
                    onChange { theme in
                        theme.dots[0] = newDot
                        theme.applyHarmony()
                    }
                }
        )
    }

    private func handleColor(_ dot: ThemeDot) -> Color {
        guard dark else { return Color(nsColor: SpaceTheme.color(for: dot, intensity: max(0.55, theme.intensity), dark: false)) }
        return Color(nsColor: NSColor(hue: dot.angle / 360, saturation: min(1, dot.radius) * 0.7, brightness: 0.4 + 0.25 * theme.intensity, alpha: 1))
    }

    private func point(for dot: ThemeDot, center: CGPoint, radius: CGFloat) -> CGPoint {
        let radians = dot.angle * .pi / 180
        return CGPoint(x: center.x + cos(radians) * dot.radius * radius, y: center.y + sin(radians) * dot.radius * radius)
    }

    private func dotFor(location: CGPoint, center: CGPoint, radius: CGFloat) -> ThemeDot {
        let dx = location.x - center.x, dy = location.y - center.y
        return ThemeDot(angle: angleDegrees(dy: dy, dx: dx).wrappedDegrees, radius: min(1, sqrt(dx * dx + dy * dy) / radius))
    }
}

struct ModePicker: View {
    let mode: ThemeMode
    let onSelect: (ThemeMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemeMode.allCases, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 24)
                        .foregroundStyle(mode == option ? .primary : .secondary)
                        .background {
                            if mode == option {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.label)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct DotStepper: View {
    let count: Int
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "minus", help: "Remove color", disabled: count <= 1, size: 11) { onStep(-1) }
            HStack(spacing: 3) {
                ForEach(0..<SpaceTheme.maxDots, id: \.self) { index in
                    Circle()
                        .fill(.primary.opacity(index < count ? 0.7 : 0.15))
                        .frame(width: 5, height: 5)
                }
            }
            IconButton(symbol: "plus", help: "Add color", disabled: count >= SpaceTheme.maxDots, size: 11) { onStep(1) }
        }
    }
}

struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(selected ? .primary : .secondary)
                .background(.primary.opacity(selected ? 0.12 : 0.04), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct WaveSlider: View {
    let value: Double
    let accent: Color
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let midY = proxy.size.height / 2
            let thumbX = 8 + (width - 16) * value
            let amplitude = 1 + 4 * value
            ZStack(alignment: .leading) {
                wave(width: width, midY: midY, amplitude: amplitude)
                    .stroke(.primary.opacity(0.14), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                wave(width: width, midY: midY, amplitude: amplitude)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .mask(alignment: .leading) { Rectangle().frame(width: thumbX) }
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 2.5, y: 1)
                    .position(x: thumbX, y: midY + sin(thumbX / 12 * 2 * .pi) * amplitude)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onChange(min(1, max(0, (drag.location.x - 8) / (width - 16))))
                    }
            )
        }
    }

    private func wave(width: CGFloat, midY: CGFloat, amplitude: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 2, y: midY + sin(2 / 12 * 2 * .pi) * amplitude))
            var x: CGFloat = 2
            while x <= width - 2 {
                path.addLine(to: CGPoint(x: x, y: midY + sin(x / 12 * 2 * .pi) * amplitude))
                x += 1
            }
        }
    }
}

struct GrainDial: View {
    let value: Double
    let accent: Color
    let onChange: (Double) -> Void

    private let steps = 16

    var body: some View {
        GeometryReader { proxy in
            dial(size: min(proxy.size.width, proxy.size.height))
        }
    }

    private func dial(size: CGFloat) -> some View {
        let center = CGPoint(x: size / 2, y: size / 2)
        let ring = size / 2 - 3
        return ZStack {
            ticks(center: center, ring: ring)
            face(size: size, center: center)
            knob(size: size, center: center)
        }
        .contentShape(Circle())
        .gesture(dragGesture(center: center))
    }

    private func ticks(center: CGPoint, ring: CGFloat) -> some View {
        ForEach(0..<steps, id: \.self) { step in
            tickMark(step: step, center: center, ring: ring)
        }
    }

    private func tickMark(step: Int, center: CGPoint, ring: CGFloat) -> some View {
        let fraction = Double(step) / Double(steps)
        let radians = (fraction * 360 - 90) * Double.pi / 180
        let active = fraction <= value && value > 0
        let style: AnyShapeStyle = active ? AnyShapeStyle(accent) : AnyShapeStyle(.primary.opacity(0.2))
        return Circle()
            .fill(style)
            .frame(width: 3.5, height: 3.5)
            .position(
                x: center.x + CGFloat(cos(radians)) * ring,
                y: center.y + CGFloat(sin(radians)) * ring
            )
    }

    private func face(size: CGFloat, center: CGPoint) -> some View {
        Circle()
            .fill(.background)
            .overlay {
                Image(nsImage: NoiseTexture.image)
                    .resizable(resizingMode: .tile)
                    .opacity(0.25 + value * 0.75)
                    .clipShape(Circle())
            }
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .frame(width: size - 16, height: size - 16)
            .position(center)
    }

    private func knob(size: CGFloat, center: CGPoint) -> some View {
        let radians = (value * 360 - 90) * Double.pi / 180
        let orbit = size / 2 - 14
        return Capsule()
            .fill(.primary.opacity(0.7))
            .frame(width: 2.5, height: 7)
            .rotationEffect(.radians(radians + .pi / 2))
            .position(
                x: center.x + CGFloat(cos(radians)) * orbit,
                y: center.y + CGFloat(sin(radians)) * orbit
            )
    }

    private func dragGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                var degrees = angleDegrees(dy: drag.location.y - center.y, dx: drag.location.x - center.x) + 90
                if degrees < 0 { degrees += 360 }
                var snapped = (degrees / 360 * Double(steps)).rounded() / Double(steps)
                if snapped >= 1 { snapped = 0 }
                if snapped != value {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    onChange(snapped)
                }
            }
    }
}

private func angleDegrees(dy: CGFloat, dx: CGFloat) -> Double {
    Double(atan2(dy, dx)) * 180 / .pi
}

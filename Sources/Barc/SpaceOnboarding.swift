import SwiftUI

struct SpaceOnboarding: View {
    @Environment(BrowserStore.self) private var store
    @State private var draft: Space
    @State private var step = 0
    @State private var forward = true
    @State private var customizing = false

    private let steps = 3

    init(initial: Space) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 18)
                ZStack(alignment: .topLeading) {
                    Group {
                        switch step {
                        case 0: nameStep
                        case 1: themeStep
                        default: dataStep
                        }
                    }
                    .id(step)
                    .transition(.push(from: forward ? .trailing : .leading))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .clipped()
                footer
                    .padding(.top, 22)
            }
            .padding(22)
            .frame(width: 468)
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
            .animation(.snappy(duration: 0.3), value: step)
            .animation(.snappy(duration: 0.25), value: customizing)
        }
    }

    private var header: some View {
        let titles = ["Name your space", "Pick a theme", "Logins & site data"]
        let subtitles = [
            "Give it a name and an icon so you can spot it in the sidebar.",
            "Every space gets its own colors. You can tweak it anytime.",
            "Choose whether this space shares cookies and sign-ins with your other spaces.",
        ]
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(0..<steps, id: \.self) { index in
                        Capsule()
                            .fill(.primary.opacity(index <= step ? 0.7 : 0.15))
                            .frame(width: index == step ? 18 : 6, height: 6)
                    }
                }
                .padding(.bottom, 6)
                Text(titles[step])
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitles[step])
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .animation(.snappy(duration: 0.25), value: step)
            Spacer(minLength: 12)
            IconButton(symbol: "xmark", help: "Cancel (Esc)", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: draft.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                CommandField(
                    text: $draft.name,
                    placeholder: "Space name",
                    selectAll: true,
                    onMove: { _ in },
                    onSubmit: next,
                    onCancel: cancel
                )
                .frame(height: 26)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 9), spacing: 6) {
                ForEach(Space.symbols, id: \.self) { symbol in
                    let selected = draft.symbol == symbol
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(.primary.opacity(selected ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { draft.symbol = symbol } }
                }
            }
        }
    }

    private var themeStep: some View {
        let palette = draft.theme.palette(systemDark: store.systemDark)
        return VStack(alignment: .leading, spacing: 14) {
            themePreview(palette: palette)

            HStack(spacing: 0) {
                ForEach(ThemePreset.allCases) { preset in
                    let presetPalette = preset.theme.palette(systemDark: store.systemDark)
                    let selected = draft.theme == preset.theme
                    ThemeBackground(palette: Palette(colors: presetPalette.colors, accent: presetPalette.accent, isDark: presetPalette.isDark, grain: 0))
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.8 : 0), lineWidth: 1.5))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { draft.theme = preset.theme } }
                        .help(preset.name)
                }
            }

            HStack(spacing: 8) {
                ModePicker(mode: draft.theme.mode) { mode in
                    withAnimation(.easeInOut(duration: 0.3)) { draft.theme.mode = mode }
                }
                Spacer()
                Chip(label: customizing ? "Hide Custom Colors" : "Custom Colors…", selected: customizing) {
                    customizing.toggle()
                }
            }

            if customizing {
                HStack {
                    Spacer()
                    ThemePad(theme: draft.theme, dark: palette.isDark) { change in change(&draft.theme) }
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    private func themePreview(palette: Palette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: draft.symbol).font(.system(size: 9, weight: .semibold))
                    Text(draft.name).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
                ForEach([0.9, 0.7, 0.8], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.primary.opacity(0.12))
                        .frame(width: 96 * width, height: 7)
                }
            }
            .frame(width: 110, alignment: .leading)
            .padding(.top, 4)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(palette.isDark ? Color(white: 0.12) : .white)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .padding(10)
        .frame(height: 104)
        .background(ThemeBackground(palette: palette))
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
    }

    private var dataStep: some View {
        let shares = draft.sharesData
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share with other spaces")
                        .font(.system(size: 13, weight: .semibold))
                    Text(shares ? "On: you stay signed in everywhere" : "Off: this space starts signed out")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Share with other spaces", isOn: $draft.sharesData.animation(.snappy(duration: 0.25)))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(14)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: shares ? "person.2.fill" : "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.06), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                Text(shares
                     ? "Cookies, logins and site data are shared with your other shared spaces, so sites you're already signed in to stay signed in here."
                     : "This space gets its own cookies, logins and storage. Great for a second account, or keeping work and personal apart. You'll sign in to sites separately here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Image(systemName: draft.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? store.suggestedSpace.name : draft.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("Change anytime from the space menu")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button {
                    forward = false
                    step -= 1
                } label: {
                    Text("Back")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: next) {
                HStack(spacing: 6) {
                    Text(step == steps - 1 ? "Create Space" : "Continue")
                    Image(systemName: step == steps - 1 ? "checkmark" : "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(.primary, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func next() {
        guard step == steps - 1 else {
            forward = true
            step += 1
            return
        }
        store.creatingSpace = false
        store.addSpace(draft)
    }

    private func cancel() {
        store.creatingSpace = false
        store.focusWebView()
    }
}

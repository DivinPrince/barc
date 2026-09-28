import AppKit
import SwiftUI

struct Suggestion: Identifiable {
    enum Kind { case open(URL), switchTab(UUID) }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String?
    let iconURL: URL?
}

struct CommandBarView: View {
    @Environment(BrowserStore.self) private var store
    let mode: CommandBarMode
    @State private var query = ""
    @State private var selection = 0

    var body: some View {
        let items = suggestions
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: mode == .newTab ? "plus.magnifyingglass" : "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(store.palette.accent)
                    CommandField(
                        text: $query,
                        placeholder: mode == .newTab ? "Search or enter address…" : "Search, enter address, or edit URL…",
                        selectAll: mode == .currentTab,
                        onMove: { delta in
                            guard !items.isEmpty else { return }
                            selection = (selection + delta + items.count) % items.count
                        },
                        onSubmit: { run(items[safe: selection]) },
                        onCancel: dismiss
                    )
                    .frame(height: 26)
                }
                .padding(.horizontal, 18)
                .frame(height: 56)

                if !items.isEmpty {
                    Divider().opacity(0.5)
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SuggestionRow(item: item, selected: index == selection, accent: store.palette.accent)
                                .onTapGesture { run(item) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 640)
            .background {
                ZStack {
                    VisualEffect(material: .popover, blending: .withinWindow)
                    Color(nsColor: .windowBackgroundColor).opacity(0.55)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
            .padding(.top, 110)
        }
        .onAppear {
            if mode == .currentTab {
                query = (store.selectedSession?.currentURL ?? store.selectedRecord?.url)?.absoluteString ?? ""
            }
        }
        .onChange(of: query) { selection = 0 }
    }

    private var suggestions: [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [Suggestion] = []
        var seen = Set<String>()

        if !text.isEmpty, let url = URLInput.resolve(text, engine: store.searchEngine) {
            let isSearch = !(URL(string: text)?.scheme != nil || URLInput.looksLikeHost(text))
            results.append(Suggestion(
                id: "primary",
                kind: .open(url),
                title: isSearch ? text : (url.host() ?? text),
                subtitle: isSearch ? "Search \(store.searchEngine.name)" : url.absoluteString,
                symbol: isSearch ? "magnifyingglass" : nil,
                iconURL: isSearch ? nil : url
            ))
            seen.insert(url.absoluteString)
        }

        let lower = text.lowercased()
        if !lower.isEmpty {
            let openTabs = store.navigableTabs.compactMap { id -> (UUID, TabRecord)? in
                guard id != store.selectedTabID, let record = store.record(id) else { return nil }
                let hay = (record.title + " " + (record.url?.absoluteString ?? "")).lowercased()
                return hay.contains(lower) ? (id, record) : nil
            }
            for (id, record) in openTabs.prefix(3) {
                results.append(Suggestion(
                    id: "tab-\(id)",
                    kind: .switchTab(id),
                    title: record.displayTitle,
                    subtitle: "Switch to Tab",
                    symbol: nil,
                    iconURL: record.url
                ))
                if let url = record.url { seen.insert(url.absoluteString) }
            }
        }

        for entry in store.historyMatches(text, limit: 8) where !seen.contains(entry.url.absoluteString) {
            seen.insert(entry.url.absoluteString)
            results.append(Suggestion(
                id: "history-\(entry.url.absoluteString)",
                kind: .open(entry.url),
                title: entry.title.isEmpty ? (entry.url.host() ?? entry.url.absoluteString) : entry.title,
                subtitle: entry.url.absoluteString,
                symbol: nil,
                iconURL: entry.url
            ))
            if results.count >= 8 { break }
        }
        return results
    }

    private func run(_ item: Suggestion?) {
        guard let item else { return }
        store.commandBar = nil
        switch item.kind {
        case .switchTab(let id):
            store.select(id)
        case .open(let url):
            if mode == .newTab { store.newTab(url) } else { store.navigate(url) }
        }
        store.focusWebView()
    }

    private func dismiss() {
        store.commandBar = nil
        store.focusWebView()
    }
}

struct SuggestionRow: View {
    let item: Suggestion
    let selected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? .white : .secondary)
                        .frame(width: 18, height: 18)
                } else {
                    FaviconView(url: item.iconURL, size: 18)
                }
            }
            .frame(width: 22)
            Text(item.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(selected ? .white : .primary)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? accent : .clear))
        .contentShape(Rectangle())
    }
}

struct CommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let selectAll: Bool
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            if selectAll {
                field.currentEditor()?.selectAll(nil)
            } else {
                field.currentEditor()?.moveToEndOfDocument(nil)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            if selectAll { field.currentEditor()?.selectAll(nil) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField

        init(_ parent: CommandField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

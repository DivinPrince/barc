import Foundation
import SwiftUI

struct TabRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL?
    var title: String
    var homeURL: URL?
    var homeTitle: String?
    var lastActive = Date()

    var displayTitle: String {
        if homeURL != nil, let homeTitle, !homeTitle.isEmpty { return homeTitle }
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }
}

struct Folder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isExpanded = true
    var tabs: [UUID] = []
    var live: LiveFeed?
}

enum PinnedItem: Codable, Identifiable, Equatable {
    case tab(UUID)
    case folder(Folder)

    var id: UUID {
        switch self {
        case .tab(let id): id
        case .folder(let folder): folder.id
        }
    }
}

struct Space: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol: String
    var theme: SpaceTheme
    var sharesData = true
    var favorites: [UUID] = []
    var pinned: [PinnedItem] = []
    var today: [UUID] = []
    var selectedTab: UUID?

    static let symbols = [
        "sparkles", "house.fill", "briefcase.fill", "book.fill", "leaf.fill", "flame.fill",
        "bolt.fill", "moon.fill", "sun.max.fill", "heart.fill", "star.fill", "gamecontroller.fill",
        "paintpalette.fill", "hammer.fill", "graduationcap.fill", "cart.fill", "music.note", "airplane",
    ]

    init(name: String, symbol: String, theme: SpaceTheme, sharesData: Bool = true) {
        self.name = name
        self.symbol = symbol
        self.theme = theme
        self.sharesData = sharesData
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, theme, sharesData, favorites, pinned, today, selectedTab
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        theme = try container.decode(SpaceTheme.self, forKey: .theme)
        sharesData = try container.decodeIfPresent(Bool.self, forKey: .sharesData) ?? true
        favorites = try container.decodeIfPresent([UUID].self, forKey: .favorites) ?? []
        pinned = try container.decodeIfPresent([PinnedItem].self, forKey: .pinned) ?? []
        today = try container.decodeIfPresent([UUID].self, forKey: .today) ?? []
        selectedTab = try container.decodeIfPresent(UUID.self, forKey: .selectedTab)
    }
}

struct HistoryEntry: Codable, Equatable {
    var url: URL
    var title: String
    var visits: Int
    var lastVisit: Date
}

@MainActor
@Observable
final class Library: @preconcurrency Decodable, Encodable {
    var spaces: [Space] = []
    var tabs: [UUID: TabRecord] = [:]
    var selectedSpace: UUID?
    var sidebarWidth: Double = 248
    var sidebarVisible = true

    init(
        spaces: [Space] = [],
        tabs: [UUID: TabRecord] = [:],
        selectedSpace: UUID? = nil,
        sidebarWidth: Double = 248,
        sidebarVisible: Bool = true
    ) {
        self.spaces = spaces
        self.tabs = tabs
        self.selectedSpace = selectedSpace
        self.sidebarWidth = sidebarWidth
        self.sidebarVisible = sidebarVisible
    }

    private enum CodingKeys: String, CodingKey {
        case favorites, spaces, tabs, selectedSpace, sidebarWidth, sidebarVisible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        tabs = try container.decodeIfPresent([UUID: TabRecord].self, forKey: .tabs) ?? [:]
        selectedSpace = try container.decodeIfPresent(UUID.self, forKey: .selectedSpace)
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 248
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        let legacyFavorites = try container.decodeIfPresent([UUID].self, forKey: .favorites) ?? []
        if !legacyFavorites.isEmpty, let s = spaces.firstIndex(where: { $0.id == selectedSpace }) ?? spaces.indices.first {
            spaces[s].favorites = legacyFavorites + spaces[s].favorites
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        try MainActor.assumeIsolated {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(spaces, forKey: .spaces)
            try container.encode(tabs, forKey: .tabs)
            try container.encode(selectedSpace, forKey: .selectedSpace)
            try container.encode(sidebarWidth, forKey: .sidebarWidth)
            try container.encode(sidebarVisible, forKey: .sidebarVisible)
        }
    }
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
    let symbol: String
}

enum Destination: Equatable {
    case favorites(space: UUID)
    case pinned(space: UUID)
    case folder(space: UUID, folder: UUID)
    case today(space: UUID)
}

enum DragPayload {
    static func tab(_ id: UUID) -> String { "barc.tab:\(id.uuidString)" }
    static func folder(_ id: UUID) -> String { "barc.folder:\(id.uuidString)" }

    enum Kind { case tab(UUID), folder(UUID) }

    static func parse(_ string: String) -> Kind? {
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "barc.tab": return .tab(id)
        case "barc.folder": return .folder(id)
        default: return nil
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, kagi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        }
    }

    func url(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .duckduckgo: components = URLComponents(string: "https://duckduckgo.com/")
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        case .kagi: components = URLComponents(string: "https://kagi.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

enum URLInput {
    static func resolve(_ raw: String, engine: SearchEngine) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) {
            return url
        }
        if looksLikeHost(text), let url = URL(string: "https://\(text)") {
            return url
        }
        return engine.url(for: text)
    }

    static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        if hostOnly == "localhost" { return true }
        if hostOnly.split(separator: ".").count == 4, hostOnly.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        let labels = hostOnly.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2 else { return false }
        return tld.allSatisfy(\.isLetter)
    }
}

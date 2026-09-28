import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    private(set) var icons: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var glowCache: [String: [Color]] = [:]
    @ObservationIgnored private var refreshedFromPage: Set<String> = []
    @ObservationIgnored private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "Barc/Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(for url: URL?) -> NSImage? {
        guard let host = url?.host() else { return nil }
        if let image = icons[host] { return image }
        ensure(host)
        return nil
    }

    private func ensure(_ host: String) {
        guard !requested.contains(host) else { return }
        requested.insert(host)
        let file = fileURL(host)
        Task {
            if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                icons[host] = image
                return
            }
            let fallback = URL(string: "https://\(host)/favicon.ico")
            if let fallback, let image = await download(fallback) {
                store(image.0, data: image.1, host: host)
            }
        }
    }

    func update(host: String, pageURL: URL, links: [[String]]) {
        guard !refreshedFromPage.contains(host) else { return }
        refreshedFromPage.insert(host)
        requested.insert(host)
        let ranked = links.compactMap { link -> (URL, Int)? in
            guard link.count >= 3, let url = URL(string: link[0]) else { return nil }
            let size = link[1].split(separator: "x").first.flatMap { Int($0) } ?? 0
            let isTouch = link[2].contains("apple-touch")
            var score = size == 0 ? (isTouch ? 180 : 32) : size
            if url.pathExtension.lowercased() == "svg" { score = 64 }
            return (url, abs(score - 64))
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
        let candidates = ranked + [URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL].compactMap { $0 }
        Task {
            for candidate in candidates {
                if let (image, data) = await download(candidate) {
                    store(image, data: data, host: host)
                    return
                }
            }
        }
    }

    func glowColors(for url: URL?) -> [Color]? {
        guard let host = url?.host(), let image = icon(for: url) else { return nil }
        if let cached = glowCache[host] { return cached }
        let colors = Self.dominantColors(image)
        glowCache[host] = colors
        return colors
    }

    static func dominantColors(_ image: NSImage) -> [Color] {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return [] }

        var halves = [(r: 0.0, g: 0.0, b: 0.0, weight: 0.0), (r: 0.0, g: 0.0, b: 0.0, weight: 0.0)]
        var all = (r: 0.0, g: 0.0, b: 0.0, weight: 0.0)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let a = Double(data[i + 3]) / 255
                guard a > 0.5 else { continue }
                let r = Double(data[i]) / 255 / a, g = Double(data[i + 1]) / 255 / a, b = Double(data[i + 2]) / 255 / a
                let maxC = max(r, g, b), minC = min(r, g, b)
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                all = (all.r + r, all.g + g, all.b + b, all.weight + 1)
                guard saturation > 0.25, maxC > 0.2 else { continue }
                let w = saturation * saturation
                let h = x < side / 2 ? 0 : 1
                halves[h] = (halves[h].r + r * w, halves[h].g + g * w, halves[h].b + b * w, halves[h].weight + w)
            }
        }
        func color(_ c: (r: Double, g: Double, b: Double, weight: Double)) -> Color? {
            guard c.weight > 0 else { return nil }
            return Color(.sRGB, red: min(1, c.r / c.weight), green: min(1, c.g / c.weight), blue: min(1, c.b / c.weight))
        }
        let left = color(halves[0]), right = color(halves[1])
        switch (left, right) {
        case let (l?, r?): return [l, r]
        case let (l?, nil): return [l, l.opacity(0.6)]
        case let (nil, r?): return [r.opacity(0.6), r]
        default:
            let gray = color(all) ?? .gray
            return [gray.opacity(0.7), gray.opacity(0.4)]
        }
    }

    private func store(_ image: NSImage, data: Data, host: String) {
        glowCache[host] = nil
        icons[host] = image
        try? data.write(to: fileURL(host))
    }

    private func fileURL(_ host: String) -> URL {
        directory.appending(path: host.replacingOccurrences(of: "/", with: "_"))
    }

    private func download(_ url: URL) async -> (NSImage, Data)? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(TabSession.userAgentSuffix)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return nil }
        return (image, data)
    }
}

@MainActor
@Observable
final class DownloadItem: Identifiable {
    let id = UUID()
    var filename: String
    var progress: Double = 0
    var fileURL: URL?
    var finished = false
    var failed = false

    init(filename: String) {
        self.filename = filename
    }
}

@MainActor
@Observable
final class DownloadCenter: NSObject {
    static let shared = DownloadCenter()

    var items: [DownloadItem] = []
    var toast: DownloadItem?
    @ObservationIgnored private var map: [ObjectIdentifier: DownloadItem] = [:]
    @ObservationIgnored private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    var active: Bool { items.contains { !$0.finished && !$0.failed } }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(filename: download.originalRequest?.url?.lastPathComponent ?? "Download")
        let key = ObjectIdentifier(download)
        map[key] = item
        items.insert(item, at: 0)
        observations[key] = download.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in item.progress = value }
        }
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        items.removeAll { $0.finished || $0.failed }
    }

    private func finish(_ download: WKDownload, failed: Bool) {
        let key = ObjectIdentifier(download)
        guard let item = map[key] else { return }
        item.finished = !failed
        item.failed = failed
        item.progress = failed ? item.progress : 1
        observations[key] = nil
        map[key] = nil
        if !failed {
            toast = item
            Task {
                try? await Task.sleep(for: .seconds(4))
                if toast === item { toast = nil }
            }
        }
    }
}

extension DownloadCenter: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var candidate = folder.appending(path: suggestedFilename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path()) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        if let item = map[ObjectIdentifier(download)] {
            item.filename = candidate.lastPathComponent
            item.fileURL = candidate
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, failed: false)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, failed: true)
    }
}

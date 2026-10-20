import Foundation
import UIKit

/// The flight's chart pack: charts pinned in the order you'll use them (departure, SID, STAR, approach, taxi…),
/// stored with their page images and georeferencing in Application Support — available offline and without the sim.
@MainActor
final class ChartPack: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        var id: String { detail.chart.guid }
        let icao: String
        let detail: ChartDetail       // page images point at files in the pack folder ("pack:<file>")
    }

    @Published private(set) var items: [Item] = []

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chartpack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexFile: URL { folder.appendingPathComponent("pack.json") }

    init() {
        if let data = try? Data(contentsOf: Self.indexFile), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func contains(_ guid: String) -> Bool { items.contains { $0.detail.chart.guid == guid } }

    func item(_ guid: String) -> Item? { items.first { $0.detail.chart.guid == guid } }

    /// Pins a chart with whatever page images are available (missing pages stay unavailable offline).
    func add(icao: String, detail: ChartDetail, images: [Int: UIImage]) {
        guard !contains(detail.chart.guid) else { return }
        var pages = detail.pages
        for (i, page) in pages.enumerated() {
            guard let image = images[page.index], let png = image.pngData() else {
                pages[i].image = nil
                continue
            }
            let name = Self.fileName(guid: detail.chart.guid, page: page.index)
            try? png.write(to: Self.folder.appendingPathComponent(name), options: .atomic)
            pages[i].image = "pack:" + name
        }
        items.append(Item(icao: icao, detail: ChartDetail(chart: detail.chart, pages: pages)))
        save()
    }

    func remove(_ guid: String) {
        guard let item = item(guid) else { return }
        for page in item.detail.pages {
            if let path = page.image, path.hasPrefix("pack:") {
                try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(String(path.dropFirst(5))))
            }
        }
        items.removeAll { $0.detail.chart.guid == guid }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }

    static func image(_ path: String) -> UIImage? {
        guard path.hasPrefix("pack:") else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(String(path.dropFirst(5))).path)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.indexFile, options: .atomic) }
    }

    private static func fileName(guid: String, page: Int) -> String {
        let safe = guid.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "_" }
        return "\(String(safe))-\(page).png"
    }
}

/// Disk cache for chart page images from the sim (via the bridge), so they survive app restarts.
enum ChartImageDiskCache {
    private static var folder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ path: String) -> URL {
        let safe = path.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "_" }
        return folder.appendingPathComponent(String(safe) + ".png")
    }

    static func load(_ path: String) -> Data? { try? Data(contentsOf: file(path)) }

    static func store(_ data: Data, for path: String) { try? data.write(to: file(path), options: .atomic) }
}

import Foundation
import CryptoKit
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
    @Published var error: String?
    private let directory: URL

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chartpack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var indexFile: URL { directory.appendingPathComponent("pack.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.folder
        guard FileManager.default.fileExists(atPath: indexFile.path) else { return }
        do {
            items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: indexFile))
        } catch {
            self.error = "Saved flight charts could not be opened."
            DiagnosticLog.record(.error, "Charts", "Saved flight chart index could not be opened.", error: error)
        }
    }

    func contains(_ guid: String) -> Bool { items.contains { $0.detail.chart.guid == guid } }

    func item(_ guid: String) -> Item? { items.first { $0.detail.chart.guid == guid } }

    /// Pins a chart only after every page and the updated index have been saved.
    func add(icao: String, detail: ChartDetail, images: [Int: UIImage]) {
        guard !contains(detail.chart.guid) else { return }
        var pages = detail.pages
        do {
            guard !pages.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            for (i, page) in pages.enumerated() {
                guard let image = images[page.index], let png = image.pngData() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let name = Self.fileName(guid: detail.chart.guid, page: page.index)
                try png.write(to: directory.appendingPathComponent(name), options: .atomic)
                pages[i].image = "pack:" + name
            }
            save(items + [Item(icao: icao, detail: ChartDetail(chart: detail.chart, pages: pages))])
        } catch {
            reportSaveError(error)
        }
    }

    func remove(_ guid: String) {
        guard let item = item(guid) else { return }
        guard save(items.filter { $0.detail.chart.guid != guid }) else { return }
        for page in item.detail.pages {
            if let path = page.image, let name = Self.imageName(path) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var updated = items
        updated.move(fromOffsets: source, toOffset: destination)
        save(updated)
    }

    static func image(_ path: String) -> UIImage? {
        guard let name = imageName(path) else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(name).path)
    }

    @discardableResult
    private func save(_ updated: [Item]) -> Bool {
        do {
            try JSONEncoder().encode(updated).write(to: indexFile, options: .atomic)
            items = updated
            error = nil
            return true
        } catch {
            reportSaveError(error)
            return false
        }
    }

    private func reportSaveError(_ error: Error) {
        self.error = "Flight charts could not be saved. Check available storage and try again."
        DiagnosticLog.record(.error, "Charts", "Flight charts could not be saved.", error: error)
    }

    private static func imageName(_ path: String) -> String? {
        guard path.hasPrefix("pack:") else { return nil }
        let name = String(path.dropFirst(5))
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
        return name
    }

    private static func fileName(guid: String, page: Int) -> String {
        let hash = SHA256.hash(data: Data(guid.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(hash)-\(page).png"
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

import Foundation
import PencilKit

/// Saves chart annotations per chart page, in chart units (independent of zoom, screen size and rotation).
/// Stored in Application Support so iOS doesn't purge them like caches.
enum AnnotationStore {
    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("annotations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "_" }
        return folder.appendingPathComponent(String(safe) + ".drawing")
    }

    static func load(_ key: String) -> PKDrawing? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, key: String) {
        if drawing.strokes.isEmpty {
            try? FileManager.default.removeItem(at: file(key))
        } else {
            try? drawing.dataRepresentation().write(to: file(key), options: .atomic)
        }
    }
}

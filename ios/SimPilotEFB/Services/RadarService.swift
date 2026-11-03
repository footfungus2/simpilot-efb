import Foundation

/// Radar precipitation frames from RainViewer's free public map index (about two hours back, one frame every ten
/// minutes). The tiles are drawn on the map as a raster layer. Free tiles stop at zoom 7, so closer in they are
/// stretched. Personal use only (RainViewer's terms): keep that in mind before sharing builds.
@MainActor
final class RadarStore: ObservableObject {
    struct Frame: Equatable {
        let time: Date
        let path: String
    }

    struct Index: Equatable {
        var host: String
        var frames: [Frame]
    }

    enum RadarError: LocalizedError {
        case unexpected
        var errorDescription: String? { "The radar service sent something unexpected." }
    }

    private static let indexURL = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
    private static let staleAfter: TimeInterval = 240

    @Published private(set) var frames: [Frame] = []
    @Published private(set) var host = "https://tilecache.rainviewer.com"
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var updated: Date?
    /// How many frames back from the newest one is shown (0 = latest).
    @Published private(set) var stepsBack = 0

    var frame: Frame? {
        let i = frames.count - 1 - stepsBack
        return frames.indices.contains(i) ? frames[i] : nil
    }

    /// MapLibre tile template of the frame on show; nil until the index has loaded.
    var tileTemplate: String? { frame.map { "\(host)\($0.path)/256/{z}/{x}/{y}/2/1_1.png" } }

    var canStepBack: Bool { stepsBack + 1 < frames.count }
    var canStepForward: Bool { stepsBack > 0 }

    func step(back: Bool) {
        if back, canStepBack { stepsBack += 1 }
        if !back, canStepForward { stepsBack -= 1 }
    }

    func showLatest() { stepsBack = 0 }

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        if !force, let updated, Date().timeIntervalSince(updated) < Self.staleAfter, error == nil { return }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.indexURL, timeoutInterval: 15)
            request.setValue("SimPilotEFB/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let index = try Self.parse(data)
            // Keep the frame that was on show when new ones arrive (they are counted from the newest).
            let shown = frame
            host = index.host
            frames = index.frames
            if let shown, let i = index.frames.firstIndex(of: shown) { stepsBack = index.frames.count - 1 - i } else { stepsBack = 0 }
            updated = Date()
            error = nil
        } catch {
            self.error = "Radar unavailable (\(error.localizedDescription))"
            DiagnosticLog.record(.warning, "Radar", "Radar index could not be loaded.", error: error)
        }
    }

    /// The host and path end up in a tile URL, so only the expected shapes are accepted.
    nonisolated static func parse(_ data: Data) throws -> Index {
        struct Raw: Decodable {
            struct Radar: Decodable {
                struct Item: Decodable { var time: Double; var path: String }
                var past: [Item]
            }
            var host: String
            var radar: Radar
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.host.range(of: "^https://[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { throw RadarError.unexpected }
        let frames = raw.radar.past
            .filter { $0.path.range(of: "^/v2/radar/[A-Za-z0-9]+$", options: .regularExpression) != nil && $0.time.isFinite }
            .map { Frame(time: Date(timeIntervalSince1970: $0.time), path: $0.path) }
            .sorted { $0.time < $1.time }
        guard !frames.isEmpty else { throw RadarError.unexpected }
        return Index(host: raw.host, frames: frames)
    }
}

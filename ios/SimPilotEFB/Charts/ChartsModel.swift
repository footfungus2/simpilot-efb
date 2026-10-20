import Combine
import CoreImage
import CoreLocation
import UIKit

/// Loads an airport's chart index and pages from the bridge, which gets them from the sim via the link panel.
@MainActor
final class ChartsModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case waitingForSim(done: Int, total: Int)
        case failed(String)
        case ready
    }

    /// Lido chart types in the order mPilot lists them.
    static let typeOrder = ["AGC", "APC", "AFC", "AOI", "LVC", "SID", "SIDPT", "SID Initial Climb", "ObstDep", "STAR", "IAC", "VAC", "MRC"]

    @Published private(set) var icao: String?
    @Published private(set) var index: ChartIndex?
    @Published private(set) var state: LoadState = .idle
    @Published var category: String?
    @Published var runwayFilter: String?
    @Published private(set) var selected: ChartMeta?
    @Published private(set) var detail: ChartDetail?
    @Published var pageIndex = 0
    @Published private(set) var image: UIImage?
    @Published private(set) var imageError: String?

    private let bridge: BridgeClient
    private var cancellables = Set<AnyCancellable>()
    private var imageCache = NSCache<NSString, UIImage>()
    private var loadTask: Task<Void, Never>?
    /// Generated test charts (used while no sim is connected), kept for the session.
    private var testDetails: [String: ChartDetail] = [:]
    private var testImages: [String: UIImage] = [:]

    /// Pinned charts for the flight, shown as the "FLIGHT" category.
    let pack: ChartPack
    static let packCategory = "FLIGHT"

    init(bridge: BridgeClient, pack: ChartPack) {
        self.bridge = bridge
        self.pack = pack
        pack.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bridge.chartEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
        // Swap test charts for the sim's Lido charts as soon as the bridge connects.
        bridge.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, case .connected = state, self.isTestCharts else { return }
                self.reloadIndex()
            }
            .store(in: &cancellables)
    }

    /// Procedures of the loaded flight at this airport (e.g. ["CLN5S"]); the matching chart opens first.
    var preferredProcedures: Set<String> = []

    /// The chart to open by default: the flight's SID/STAR if there's one, else the first in the list.
    private func defaultChart() -> ChartMeta? {
        let norm = { (s: String) in s.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "") }
        let wanted = Set(preferredProcedures.map(norm))
        if !wanted.isEmpty, let match = index?.categories.flatMap(\.charts).first(where: { chart in
            chart.procedures.contains { p in wanted.contains(norm(p)) || wanted.contains { norm(p).hasPrefix($0) } }
        }) {
            category = index?.categories.first { $0.charts.contains(match) }?.name
            return match
        }
        return visibleCharts.first
    }

    /// True while showing generated test charts instead of the sim's Lido charts.
    var isTestCharts: Bool { index?.provider == TestCharts.provider }

    var categories: [String] {
        let names = index?.categories.filter { !$0.charts.isEmpty }.map(\.name) ?? []
        let sorted = names.sorted { (Self.typeOrder.firstIndex(of: $0) ?? 99, $0) < (Self.typeOrder.firstIndex(of: $1) ?? 99, $1) }
        return pack.items.isEmpty ? sorted : [Self.packCategory] + sorted
    }

    /// Pinned charts, labelled with their airport since the pack spans the whole flight.
    var packCharts: [ChartMeta] {
        pack.items.map { item in
            var meta = item.detail.chart
            meta.name = "\(item.icao) · \(meta.name)"
            return meta
        }
    }

    var runways: [String] {
        let all = index?.categories.flatMap(\.charts).flatMap(\.runways) ?? []
        return Array(Set(all)).sorted()
    }

    /// Charts in the selected category, filtered by runway (charts without runways always show).
    var visibleCharts: [ChartMeta] {
        let cat = category ?? categories.first
        if cat == Self.packCategory { return packCharts }
        let charts = index?.categories.first { $0.name == cat }?.charts ?? []
        guard let rwy = runwayFilter else { return charts }
        return charts.filter { $0.runways.isEmpty || $0.runways.contains(rwy) }
    }

    /// Flat list across categories, in display order, for the toolbar's previous/next buttons.
    var allChartsInOrder: [ChartMeta] {
        if category == Self.packCategory { return packCharts }
        return categories.flatMap { name in index?.categories.first { $0.name == name }?.charts ?? [] }
    }

    func open(icao newIcao: String) {
        guard newIcao != icao else { return }
        icao = newIcao
        index = nil
        selected = nil
        detail = nil
        image = nil
        category = nil
        runwayFilter = nil
        reloadIndex()
    }

    func reloadIndex() {
        guard let icao else { return }
        state = .loading
        loadTask?.cancel()
        guard bridge.isConnected else {
            loadTestCharts(icao)
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let idx: ChartIndex = try await bridge.get("/api/charts/\(icao)") {
                    guard self.icao == icao else { return }
                    index = idx
                    state = idx.categories.allSatisfy(\.charts.isEmpty) ? .failed("No Lido charts for \(icao) in the sim.") : .ready
                    if selected == nil, let first = defaultChart() { select(first) }
                } else {
                    // 202: the bridge queued a job for the in-sim link; wait for chartsReady.
                    state = .waitingForSim(done: 0, total: 0)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// No sim connected: test charts generated from the airport map data, plus any bundled debug charts.
    private func loadTestCharts(_ icao: String) {
        loadTask = Task { [weak self] in
            // Airport map data is optional: bundled debug charts still load without it.
            let features = (try? await AirportMapService.features(icao: icao)) ?? []
            let name = VatsimReference.shared.airports[icao]?.name
            let result = await Task.detached(priority: .userInitiated) {
                TestCharts.build(icao: icao, name: name, features: features)
            }.value
            guard let self, self.icao == icao else { return }
            guard let result else {
                self.state = .failed("No sim connected, and no airport map data or bundled charts for \(icao).")
                return
            }
            self.testDetails.merge(result.details) { $1 }
            self.testImages.merge(result.images) { $1 }
            self.index = result.index
            self.state = .ready
            if self.selected == nil, let first = self.defaultChart() { self.select(first) }
        }
    }

    func select(_ chart: ChartMeta) {
        selected = chart
        pageIndex = 0
        detail = nil
        image = nil
        imageError = nil
        // Pinned charts open from the iPad's storage — no sim or network needed.
        if let item = pack.item(chart.guid) {
            if item.icao != icao {
                icao = item.icao
                index = nil
                reloadIndex()
            }
            detail = item.detail
            Task { await loadPage() }
            return
        }
        guard let icao else { return }
        if let test = testDetails[chart.guid] {
            detail = test
            Task { await loadPage() }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let d: ChartDetail? = try await bridge.get("/api/charts/\(icao)/\(chart.guid.urlPathEncoded)")
                guard selected?.guid == chart.guid else { return }
                detail = d
                await loadPage()
            } catch {
                imageError = error.localizedDescription
            }
        }
    }

    func step(_ delta: Int) {
        let all = allChartsInOrder
        guard let cur = selected, let i = all.firstIndex(of: cur) else { return }
        let j = i + delta
        guard all.indices.contains(j) else { return }
        let target = all[j]
        if category != Self.packCategory { category = index?.categories.first { $0.charts.contains(target) }?.name }
        select(target)
    }

    func setPage(_ p: Int) {
        guard let pages = detail?.pages, pages.indices.contains(p) else { return }
        pageIndex = p
        Task { await loadPage() }
    }

    var currentPage: ChartPage? { detail?.pages[safe: pageIndex] }

    private func loadPage() async {
        guard let page = currentPage else { return }
        guard let path = page.image else {
            image = nil
            imageError = "This page's image couldn't be exported from the sim."
            return
        }
        do {
            let img = try await pageImage(path)
            if currentPage?.image == path { image = img; imageError = nil }
        } catch {
            imageError = error.localizedDescription
        }
    }

    /// A page image from wherever it lives: pinned pack, generated test charts, memory, disk cache, then the bridge.
    private func pageImage(_ path: String) async throws -> UIImage {
        if let packed = ChartPack.image(path) { return packed }
        if let test = testImages[path] { return test }
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        if let data = ChartImageDiskCache.load(path), let img = UIImage(data: data) {
            imageCache.setObject(img, forKey: path as NSString)
            return img
        }
        let data = try await bridge.data(path)
        guard let img = UIImage(data: data) else { throw BridgeClient.HTTPError(status: 0, message: "Invalid image") }
        imageCache.setObject(img, forKey: path as NSString)
        ChartImageDiskCache.store(data, for: path) // keep sim charts between sessions
        return img
    }

    var isSelectedPinned: Bool { selected.map { pack.contains($0.guid) } ?? false }

    /// Pins the selected chart (all its pages) to the flight pack, or unpins it.
    func togglePin() async {
        guard let chart = selected else { return }
        if pack.contains(chart.guid) {
            pack.remove(chart.guid)
            if category == Self.packCategory, packCharts.isEmpty { category = nil }
            return
        }
        guard let detail, let icao else { return }
        var images: [Int: UIImage] = [:]
        for page in detail.pages {
            if let path = page.image, let img = try? await pageImage(path) { images[page.index] = img }
        }
        pack.add(icao: icao, detail: detail, images: images)
    }

    /// The current page cropped to its georeferenced area, with that area's corner coordinates,
    /// for laying the chart over the moving map. Nil when the page isn't georeferenced.
    func overlayForCurrentPage() -> ChartOverlay? {
        guard let page = currentPage, let image, let chart = selected,
              let area = page.areas.first(where: { $0.geoReferenced }), let proj = ChartGeoProjection(area: area),
              page.width > 0, let cg = image.cgImage else { return nil }
        let r = area.chartRect
        let x0 = min(r.upperLeft[0], r.lowerRight[0]), x1 = max(r.upperLeft[0], r.lowerRight[0])
        let y0 = min(r.upperLeft[1], r.lowerRight[1]), y1 = max(r.upperLeft[1], r.lowerRight[1])
        // chart units → image pixels
        let k = Double(cg.width) / page.width
        let crop = CGRect(x: x0 * k, y: y0 * k, width: (x1 - x0) * k, height: (y1 - y0) * k).integral
        guard let cropped = cg.cropping(to: crop) else { return nil }
        func coord(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
            let ll = proj.unproject(CGPoint(x: x, y: y))
            return CLLocationCoordinate2D(latitude: ll.lat, longitude: ll.lon)
        }
        return ChartOverlay(title: "\(icao ?? "") \(chart.type) · \(chart.name)",
                            image: UIImage(cgImage: cropped),
                            topLeft: coord(x0, y0), topRight: coord(x1, y0),
                            bottomRight: coord(x1, y1), bottomLeft: coord(x0, y1))
    }

    private func handle(_ event: ChartEvent) {
        switch event {
        case let .progress(i, done, total) where i == icao:
            state = .waitingForSim(done: done, total: total)
        case let .ready(i) where i == icao:
            if index == nil || state != .ready { reloadIndex() }
        case let .error(i, message) where i == icao:
            state = .failed(message)
        default:
            break
        }
    }
}

/// A chart page pinned onto the moving map at its real position.
struct ChartOverlay: Identifiable {
    let id = UUID()
    let title: String
    let image: UIImage
    let topLeft: CLLocationCoordinate2D
    let topRight: CLLocationCoordinate2D
    let bottomRight: CLLocationCoordinate2D
    let bottomLeft: CLLocationCoordinate2D
}

enum NightChart {
    private static let context = CIContext()

    /// Night version of a white chart: invert, then rotate hue back so colours keep their meaning.
    static func render(_ image: UIImage) -> UIImage {
        guard let ci = CIImage(image: image),
              let invert = CIFilter(name: "CIColorInvert") else { return image }
        invert.setValue(ci, forKey: kCIInputImageKey)
        guard let inverted = invert.outputImage, let hue = CIFilter(name: "CIHueAdjust") else { return image }
        hue.setValue(inverted, forKey: kCIInputImageKey)
        hue.setValue(Double.pi, forKey: kCIInputAngleKey)
        guard let out = hue.outputImage, let cg = context.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

extension String {
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}

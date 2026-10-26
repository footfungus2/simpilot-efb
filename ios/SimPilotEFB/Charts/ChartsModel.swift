import Combine
import CoreImage
import CoreLocation
import UIKit

/// Loads an airport's chart list from the bridge right away; a chart's pages are exported from the sim (by the
/// link panel) when the chart is first opened, then kept on the PC and the iPad.
@MainActor
final class ChartsModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case waitingForSim
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
    /// While the sim is exporting the selected chart: pages done so far (total is 0 until the sim has sent the pages).
    @Published private(set) var exportProgress: ExportProgress?

    struct ExportProgress: Equatable {
        var done: Int
        var total: Int
    }

    private let bridge: BridgeClient
    private var cancellables = Set<AnyCancellable>()
    private var imageCache = NSCache<NSString, UIImage>()
    private var loadTask: Task<Void, Never>?
    #if DEBUG
    /// Offline charts bundled with debug builds (used while no sim is connected), rendered once per airport.
    private var offlineCharts: [String: [BundledCharts.Chart]] = [:]
    #endif

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
        // Swap offline charts for the sim's Lido charts as soon as the bridge connects.
        bridge.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, case .connected = state else { return }
                if self.isOfflineCharts || self.isWaitingOrFailed { self.reloadIndex() }
                self.askAgainForSelectedChart()
            }
            .store(in: &cancellables)
        // …and again when the SimPilot Link panel comes online in the sim, so a request the bridge lost
        // (e.g. it was restarted before the panel was opened) is sent again.
        bridge.$status
            .map { $0?.link.connected == true }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] linkUp in
                guard let self, linkUp else { return }
                if self.isOfflineCharts || self.isWaitingForPanel { self.reloadIndex() }
                self.askAgainForSelectedChart()
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

    private var isWaitingOrFailed: Bool {
        switch state {
        case .waitingForSim, .failed: return true
        default: return false
        }
    }

    private var isWaitingForPanel: Bool {
        if case .waitingForSim = state { return true }
        return false
    }

    /// A chart the sim was still exporting when the bridge restarted (or before the panel was open) is asked for again.
    private func askAgainForSelectedChart() {
        if exportProgress != nil, let chart = selected { loadDetail(chart) }
    }

    /// True while showing the offline charts bundled with debug builds instead of the sim's Lido charts.
    var isOfflineCharts: Bool {
        #if DEBUG
        return index?.provider == BundledCharts.provider
        #else
        return false
        #endif
    }

    #if DEBUG
    /// "Offline UK AIP charts" for the airport shown.
    var offlineChartsTitle: String {
        BundledCharts.title(for: icao.flatMap { offlineCharts[$0] } ?? [])
    }
    #endif

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
        exportProgress = nil
        category = nil
        runwayFilter = nil
        reloadIndex()
    }

    /// `silently` keeps the list on screen while it is fetched again (a refreshed list from the sim).
    func reloadIndex(silently: Bool = false) {
        guard let icao else { return }
        if !silently { state = .loading }
        loadTask?.cancel()
        guard bridge.isConnected else {
            #if DEBUG
            loadOfflineCharts(icao)
            #else
            state = .failed(noBridgeMessage)
            #endif
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let idx: ChartIndex = try await bridge.get("/api/charts/\(icao)") {
                    guard !Task.isCancelled, self.icao == icao else { return }
                    index = idx
                    state = idx.categories.allSatisfy(\.charts.isEmpty) ? .failed("No Lido charts for \(icao) in the sim.") : .ready
                    if selected == nil, let first = defaultChart() { select(first) }
                } else {
                    guard !Task.isCancelled, self.icao == icao else { return }
                    // 202: the bridge queued the list for the in-sim link; wait for chartsReady.
                    state = .waitingForSim
                }
            } catch {
                guard !Task.isCancelled, self.icao == icao else { return }
                state = .failed(error.localizedDescription)
                DiagnosticLog.record(.error, "Charts", "Chart index could not be loaded.", error: error)
            }
        }
    }

    /// Why there are no charts without the PC bridge.
    private var noBridgeMessage: String {
        pack.items.isEmpty
            ? "Connect the PC bridge and open SimPilot Link in MSFS to load charts. Pin flight charts to keep them available offline."
            : "PC bridge not connected. Saved charts are available in ★ FLIGHT."
    }

    #if DEBUG
    /// No sim connected: the real charts bundled with debug builds, if there are any for this airport.
    private func loadOfflineCharts(_ icao: String) {
        let cached = offlineCharts[icao]
        loadTask = Task { [weak self] in
            let charts: [BundledCharts.Chart]
            if let cached {
                charts = cached
            } else {
                // Rendering the PDFs takes a moment, so it runs off the main thread.
                charts = await Task.detached(priority: .userInitiated) { BundledCharts.charts(for: icao) }.value
            }
            guard !Task.isCancelled, let self, self.icao == icao else { return }
            guard !charts.isEmpty else {
                self.state = .failed(self.noBridgeMessage)
                return
            }
            self.offlineCharts[icao] = charts
            self.index = BundledCharts.index(icao: icao, charts: charts)
            self.state = .ready
            if self.selected == nil, let first = self.defaultChart() { self.select(first) }
        }
    }

    private func offlineChart(guid: String) -> BundledCharts.Chart? {
        offlineCharts.values.lazy.flatMap { $0 }.first { $0.detail.chart.guid == guid }
    }

    private func offlineImage(path: String) -> UIImage? {
        offlineCharts.values.lazy.flatMap { $0 }.first { $0.imagePath == path }?.image
    }

    /// Earlier debug builds generated placeholder charts from OpenStreetMap ("test-EGSS-AGC"); drops any that were pinned.
    static func removePlaceholderCharts(from pack: ChartPack) {
        for item in pack.items where item.id.hasPrefix("test-") { pack.remove(item.id) }
    }
    #endif

    func select(_ chart: ChartMeta) {
        selected = chart
        pageIndex = 0
        detail = nil
        image = nil
        imageError = nil
        exportProgress = nil
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
        #if DEBUG
        if let offline = offlineChart(guid: chart.guid) {
            detail = offline.detail
            Task { await loadPage() }
            return
        }
        #endif
        loadDetail(chart)
    }

    /// Asks the bridge for the chart's pages. If the sim still has to export them (202), `exportProgress` shows
    /// that and the bridge's chartReady / chartError events finish the job. `refresh` has them exported again.
    private func loadDetail(_ chart: ChartMeta, refresh: Bool = false) {
        guard let icao else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let d: ChartDetail? = try await bridge.get("/api/charts/\(icao)/\(chart.guid.urlPathEncoded)\(refresh ? "?refresh=1" : "")")
                guard selected?.guid == chart.guid, self.icao == icao else { return }
                guard let d else {
                    if detail == nil, exportProgress == nil { exportProgress = ExportProgress(done: 0, total: 0) }
                    return
                }
                exportProgress = nil
                detail = d
                await loadPage()
            } catch {
                guard selected?.guid == chart.guid, self.icao == icao else { return }
                exportProgress = nil
                imageError = error.localizedDescription
                DiagnosticLog.record(.error, "Charts", "Chart details could not be loaded.", error: error)
            }
        }
    }

    /// Whether "export again" applies: the selected chart comes from the sim (not a pinned or bundled chart).
    var canReexport: Bool {
        guard let chart = selected, bridge.isConnected, !isOfflineCharts, !pack.contains(chart.guid) else { return false }
        return true
    }

    /// Tries the selected chart again; with `reexport` the sim exports its pages again even if they are saved.
    func reloadSelected(reexport: Bool = false) {
        guard let chart = selected else { return }
        guard reexport else { return select(chart) }
        detail = nil
        image = nil
        imageError = nil
        exportProgress = nil
        loadDetail(chart, refresh: reexport)
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
        image = nil
        imageError = nil
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
            guard currentPage?.image == path else { return }
            imageError = error.localizedDescription
            DiagnosticLog.record(.error, "Charts", "Chart page could not be loaded.", error: error)
        }
    }

    /// A page image from wherever it lives: pinned pack, offline charts, memory, disk cache, then the bridge.
    private func pageImage(_ path: String) async throws -> UIImage {
        if let packed = ChartPack.image(path) { return packed }
        if path.hasPrefix("pack:") {
            throw BridgeClient.HTTPError(status: 0, message: "Saved chart image is missing. Connect to the sim and pin the chart again.")
        }
        #if DEBUG
        if let offline = offlineImage(path: path) { return offline }
        #endif
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
        do {
            for page in detail.pages {
                guard let path = page.image else {
                    throw BridgeClient.HTTPError(status: 0, message: "This chart has pages that have not been exported yet.")
                }
                images[page.index] = try await pageImage(path)
            }
            pack.add(icao: icao, detail: detail, images: images)
        } catch {
            pack.error = "The complete chart could not be downloaded. Keep SimPilot Link open and try again."
            DiagnosticLog.record(.error, "Charts", "Flight chart could not be downloaded for offline use.", error: error)
        }
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
        case let .ready(i) where i == icao:
            reloadIndex(silently: index != nil && state == .ready)
        case let .error(i, message) where i == icao:
            if state != .ready { state = .failed(message) }
        case let .chartProgress(i, guid, done, total) where i == icao && guid == selected?.guid && exportProgress != nil:
            exportProgress = ExportProgress(done: done, total: total)
        case let .chartReady(i, guid) where i == icao && guid == selected?.guid:
            if let chart = selected { loadDetail(chart) }
        case let .chartError(i, guid, message) where i == icao && guid == selected?.guid:
            exportProgress = nil
            imageError = message
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

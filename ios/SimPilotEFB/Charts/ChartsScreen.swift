import SwiftUI

/// Charts module: chart list sidebar (category tabs, runway filter) and the chart viewer.
struct ChartsScreen: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Binding var navigation: ChartNavigation?

    var body: some View {
        ChartsContent(model: app.chartsModel, ownshipStore: bridge.ownship, navigation: $navigation)
    }
}

private struct ChartsContent: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @ObservedObject var model: ChartsModel
    @ObservedObject var ownshipStore: OwnshipStore
    @Binding var navigation: ChartNavigation?
    @State private var followAircraft = false

    var body: some View {
        HStack(spacing: 0) {
            if app.sidebarVisible {
                ChartListSidebar(model: model)
                    .frame(width: 310)
                    .transition(.slide(from: .leading))
            }
            viewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(app.night ? Color(hex: 0x111317) : Color(hex: 0xE9EAEE))
            if app.splitView {
                // Split view: the live moving map beside the chart, each with its own zoom (mPilot's AMM + chart).
                HStack(spacing: 0) {
                    Rectangle().fill(theme.separator).frame(width: 1)
                    EnrouteMapScreen()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .transition(.slide(from: .trailing))
            }
        }
        .animation(Motion.layout, value: app.splitView)
        .animation(Motion.layout, value: app.sidebarVisible)
        .onAppear(perform: sync)
        .onChange(of: app.chartsAirport) { _ in sync() }
        .onChange(of: model.selected) { _ in updateNavigation() }
        .onChange(of: model.index) { _ in updateNavigation() }
        .alert("Flight Charts", isPresented: Binding(get: { model.pack.error != nil }, set: { if !$0 { model.pack.error = nil } })) {
            Button("OK", role: .cancel) { model.pack.error = nil }
        } message: {
            Text(model.pack.error ?? "")
        }
    }

    /// What the viewer area shows; content swaps cross-fade when it changes (never on ownship updates).
    private var viewerPhase: String {
        guard model.selected != nil else {
            switch model.state {
            case .idle: return "idle"
            case .loading: return "loading"
            case .waitingForSim: return "waiting"
            case .failed: return "failed"
            case .ready: return "ready"
            }
        }
        let content = model.image != nil && model.currentPage != nil ? "page" : model.imageError != nil ? "error" : "skeleton"
        return "\(content)|\(model.detail != nil)"
    }

    private var viewer: some View {
        ZStack {
            if model.selected != nil {
                chartViewer
                    .transition(.opacity)
            } else {
                indexState
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: viewerPhase)
    }

    /// The selected chart: the page (or its loading skeleton), with the page picker and side buttons staying put
    /// while pages load.
    private var chartViewer: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if let image = model.image, let page = model.currentPage, let chart = model.selected {
                    ZoomableChartView(image: image, dark: app.night && app.invertChartsAtNight, page: page, ownship: ownshipStore.ownship,
                                      resetKey: "\(chart.guid)#\(model.pageIndex)",
                                      follow: followAircraft, onUserPan: { followAircraft = false },
                                      annotating: app.annotating, clearToken: app.annotationClearToken)
                        .transition(.screen)
                } else if let error = model.imageError {
                    VStack(spacing: 12) {
                        message(error, systemImage: "exclamationmark.triangle")
                        GreyPillButton(title: "Retry") { model.reloadSelected() }.frame(width: 160)
                    }
                    .transition(.opacity)
                } else {
                    ChartPageSkeleton()
                        .overlay(exportStatus)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if app.annotating {
                    AnnotateBar(onClear: { app.annotationClearToken += 1 }, onDone: { app.annotating = false })
                        .padding(.top, 12)
                        .transition(.dropDown)
                }
            }
            if let pages = model.detail?.pages, pages.count > 1 {
                PagePicker(count: pages.count, page: Binding(get: { model.pageIndex }, set: { model.setPage($0) }))
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            sideButtons(model.currentPage)
        }
        .animation(Motion.bouncy, value: app.annotating)
    }

    /// While the sim exports the chart the skeleton stands in for the page; this says what is going on.
    @ViewBuilder private var exportStatus: some View {
        if let progress = model.exportProgress {
            VStack(spacing: 6) {
                Text(progress.total > 1 ? "Exporting from the sim… page \(min(progress.done + 1, progress.total)) of \(progress.total)" : "Exporting from the sim…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)
                Text(bridge.status?.link.connected == true ? "Keep SimPilot Link open and visible in MSFS." : "Open SimPilot Link in the MSFS toolbar.")
                    .font(.footnote)
                    .foregroundColor(theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.overlay))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
    }

    /// Pin (always, so it stays put from chart to chart), export again for sim charts, plus Show on map and Follow aircraft on georeferenced pages.
    private func sideButtons(_ page: ChartPage?) -> some View {
        VStack(spacing: 10) {
            chartButton(model.isSelectedPinned ? "pin.fill" : "pin", label: model.isSelectedPinned ? "Unpin from flight" : "Pin to flight",
                        active: model.isSelectedPinned) {
                Task { await model.togglePin() }
            }
            if model.canReexport {
                chartButton("arrow.clockwise", label: "Export again from the sim", active: false) { model.reloadSelected(reexport: true) }
                    .transition(.opacity)
            }
            if let page, page.geoReferenced {
                chartButton("rectangle.on.rectangle", label: "Show on map", active: false) {
                    if let overlay = model.overlayForCurrentPage() {
                        app.chartOverlay = overlay
                        app.followOwnship = false
                        app.module = .map
                    }
                }
                .transition(.opacity)
                chartButton("location.north.fill", label: "Follow aircraft", active: followAircraft) {
                    followAircraft.toggle()
                }
                .disabled(ownshipStore.ownship.flatMap { page.position(lat: $0.lat, lon: $0.lon) } == nil)
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    @ViewBuilder private var indexState: some View {
        switch model.state {
        case .idle:
            message("Choose an airport in the Flight Folder or with Search.", systemImage: "doc.text.magnifyingglass")
        case .loading:
            // Same placeholder as a loading page, so index → first chart reads as one load.
            ChartPageSkeleton()
        case .waitingForSim:
            let linkUp = bridge.status?.link.connected == true
            VStack(spacing: 14) {
                ProgressView()
                Text(linkUp ? "Getting the chart list from the sim…" : "Open SimPilot Link in MSFS")
                    .foregroundColor(theme.text)
                Text(linkUp ? "Each chart is exported from the sim the first time you open it."
                            : "In a flight, click SimPilot Link in the MSFS toolbar. The chart list appears as soon as it is open.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(theme.textSecondary)
            }
            .padding()
        case let .failed(msg):
            VStack(spacing: 12) {
                message(msg, systemImage: "exclamationmark.triangle")
                GreyPillButton(title: "Retry") { model.reloadIndex() }.frame(width: 160)
            }
        case .ready:
            message("Select a chart.", systemImage: "doc")
        }
    }

    private func chartButton(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                // A new symbol (pin → pinned) pops in over the old one.
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .rotationEffect(.degrees(symbol == "location.north.fill" ? 45 : 0))
                    .foregroundColor(active ? Theme.ownshipBlue : theme.text)
                    .id(symbol)
                    .transition(.pop)
            }
            .frame(width: 48, height: 48)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.overlay))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            .animation(Motion.bouncy, value: symbol)
            .animation(Motion.smooth, value: active)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundColor(theme.textSecondary)
            Text(text).multilineTextAlignment(.center).foregroundColor(theme.text)
        }
        .padding(40)
    }

    private func sync() {
        if let icao = app.chartsAirport { model.open(icao: icao) }
        updateNavigation()
    }

    private func updateNavigation() {
        let all = model.allChartsInOrder
        let i = model.selected.flatMap { all.firstIndex(of: $0) }
        navigation = ChartNavigation(
            currentType: model.selected?.type,
            hasPrevious: (i ?? 0) > 0,
            hasNext: i.map { $0 < all.count - 1 } ?? false,
            previous: { [weak model] in model?.step(-1) },
            next: { [weak model] in model?.step(1) }
        )
    }
}

private struct ChartListSidebar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @ObservedObject var model: ChartsModel
    @Namespace private var selection
    /// Set once the list is on screen: lists that load after that (index, category, runway filter) stagger in,
    /// while the list that's there when the module opens comes in with the screen.
    @State private var appeared = false

    #if DEBUG
    /// Why the offline charts are showing instead of the sim's charts.
    private var offlineChartsReason: String {
        let charts = model.offlineChartsTitle
        guard bridge.isConnected else { return "\(charts) — PC bridge not connected" }
        if bridge.status?.link.connected == true {
            if case .waitingForSim = model.state { return "\(charts) — loading the sim's charts…" }
            return "\(charts) — the sim has no charts for this airport"
        }
        return "\(charts) — open SimPilot Link from the MSFS toolbar to load the sim's charts"
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.module = .map } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                }
                .buttonStyle(.pressable)
                Spacer()
                VStack(spacing: 1) {
                    Text(model.icao ?? "Charts").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                    if let name = airportName {
                        Text(name).font(.system(size: 12)).foregroundColor(theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
                runwayMenu
            }
            .padding(.horizontal, 16)
            .frame(height: 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.categories.enumerated()), id: \.element) { i, cat in
                        let active = activeCategory == cat
                        Button { model.category = cat } label: {
                            Text(cat == ChartsModel.packCategory ? "★ FLIGHT" : cat)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(active ? .white : theme.text)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(
                                    // The blue capsule slides from tab to tab.
                                    ZStack {
                                        Capsule().fill(theme.pillStrong)
                                        if active {
                                            Capsule().fill(Theme.selectedBlue)
                                                .matchedGeometryEffect(id: "category", in: selection)
                                        }
                                    }
                                )
                        }
                        .buttonStyle(.pressable)
                        .staggeredEntrance(i, active: appeared)
                    }
                }
                .padding(.horizontal, 12)
                .animation(Motion.snappy, value: activeCategory)
            }
            .padding(.bottom, 10)

            #if DEBUG
            if model.isOfflineCharts {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "internaldrive").font(.system(size: 11)).padding(.top, 2)
                    Text(offlineChartsReason).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(Theme.warnOrange)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            #endif

            Rectangle().fill(theme.separator).frame(height: 1)

            ScrollView {
                if model.index == nil && loadingIndex {
                    ChartListSkeleton()
                } else {
                    ChartRows(model: model, charts: model.visibleCharts, cascade: appeared, selection: selection)
                        .id(listGeneration)
                }
            }
            // A new list replaces the old one at once, even inside someone else's withAnimation (an animated swap
            // would stack both lists in the scroll view); then its first rows cascade in.
            .animation(nil, value: listGeneration)
        }
        .background(theme.sidebar)
        .onAppear { appeared = true }
    }

    private var activeCategory: String? { model.category ?? model.categories.first }

    private var loadingIndex: Bool {
        switch model.state {
        case .loading, .waitingForSim: return true
        default: return false
        }
    }

    /// Changes whenever a different list is shown: another airport, index, category or runway filter.
    private var listGeneration: String {
        "\(model.icao ?? "")|\(model.index?.fetchedAt ?? 0)|\(activeCategory ?? "")|\(model.runwayFilter ?? "")"
    }

    private var airportName: String? {
        app.flightAirports.first { $0.icao == model.icao }?.name
    }

    private var runwayMenu: some View {
        Menu {
            Button("All runways") { model.runwayFilter = nil }
            ForEach(model.runways, id: \.self) { rwy in
                Button("RWY \(rwy)") { model.runwayFilter = rwy }
            }
        } label: {
            Text(model.runwayFilter.map { "RWY \($0)" } ?? "RWY")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(model.runwayFilter == nil ? theme.pillStrong : Theme.selectedBlue))
                .animation(Motion.smooth, value: model.runwayFilter)
        }
        .disabled(model.runways.isEmpty)
    }
}

/// One list of charts. Each new list (airport, index, category, runway filter) gets a fresh identity, so the rows
/// built with it can cascade in; rows built later while scrolling just appear.
private struct ChartRows: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: ChartsModel
    let charts: [ChartMeta]
    let cascade: Bool
    let selection: Namespace.ID
    @State private var gate = EntranceGate()

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(charts.enumerated()), id: \.element.id) { i, chart in
                row(chart)
                    .staggeredEntrance(i, active: cascade && gate.open)
            }
        }
        .animation(Motion.snappy, value: model.selected?.guid)
        .onAppear {
            let gate = gate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { gate.open = false }
        }
    }

    private func row(_ chart: ChartMeta) -> some View {
        let active = model.selected == chart
        return Button { model.select(chart) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(chart.name).font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text).lineLimit(2)
                let sub = (chart.procedures.isEmpty ? chart.runways.map { "RWY \($0)" } : chart.procedures).joined(separator: ", ")
                if !sub.isEmpty {
                    Text(sub).font(.system(size: 12)).foregroundColor(theme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                // The highlight slides to the newly selected chart.
                ZStack {
                    if active {
                        Theme.selectedBlue.opacity(0.25)
                            .matchedGeometryEffect(id: "chart", in: selection)
                    }
                }
            )
            .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableSoft)
    }
}

/// Shimmering rows while an airport's chart index loads.
private struct ChartListSkeleton: View {
    @Environment(\.theme) private var theme
    private static let widths: [(CGFloat, CGFloat)] = [(170, 90), (140, 70), (190, 110), (150, 80), (175, 60), (130, 95)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.widths.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBlock(width: Self.widths[i].0, height: 13)
                    SkeletonBlock(width: Self.widths[i].1, height: 9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading charts")
    }
}

/// Open while a list is being built (its first layout passes); rows created after it closes don't animate in.
private final class EntranceGate {
    var open = true
}

private struct PagePicker: View {
    @Environment(\.theme) private var theme
    @Namespace private var selection
    let count: Int
    @Binding var page: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Button { page = i } label: {
                    Text("\(i + 1)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(i == page ? .white : theme.text)
                        .frame(width: 30, height: 26)
                        .background(
                            ZStack {
                                if i == page {
                                    Capsule().fill(Theme.selectedBlue)
                                        .matchedGeometryEffect(id: "page", in: selection)
                                }
                            }
                        )
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(4)
        .background(Capsule().fill(theme.overlay))
        .animation(Motion.snappy, value: page)
    }
}

/// Shown while annotating: what's happening, clear this page, done.
private struct AnnotateBar: View {
    @Environment(\.theme) private var theme
    let onClear: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "pencil.tip").foregroundColor(Theme.selectedBlue)
            Text("Annotating · two fingers to pan").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.text)
            Button("Clear page", action: onClear).buttonStyle(.pressable).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.warnOrange)
            Button("Done", action: onDone).buttonStyle(.pressable).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.selectedBlue)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(theme.overlay))
        .overlay(Capsule().stroke(theme.separator))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// Shimmering stand-in for a chart page while it loads: a page outline with a title block, the plan view and a
/// footer, sized like a portrait chart.
private struct ChartPageSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let height = max(min(geo.size.height - 56, (geo.size.width - 56) / 0.7), 0)
            let width = height * 0.7
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: width * 0.28, height: 12)
                        SkeletonBlock(width: width * 0.42, height: 9)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: width * 0.18, height: 12)
                }
                SkeletonBlock(height: 7)
                SkeletonBlock(height: nil, cornerRadius: 6)
                HStack {
                    SkeletonBlock(width: width * 0.32, height: 9)
                    Spacer(minLength: 0)
                    SkeletonBlock(width: width * 0.22, height: 9)
                }
            }
            .padding(width * 0.06)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.sidebar))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading chart")
    }
}

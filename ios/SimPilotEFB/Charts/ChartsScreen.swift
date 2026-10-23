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
                    .transition(.move(edge: .leading))
            }
            viewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(app.night ? Color(hex: 0x111317) : Color(hex: 0xE9EAEE))
            if app.splitView {
                // Split view: the live moving map beside the chart, each with its own zoom (mPilot's AMM + chart).
                Rectangle().fill(theme.separator).frame(width: 1)
                EnrouteMapScreen()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.splitView)
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

    @ViewBuilder private var viewer: some View {
        if let image = model.image, let page = model.currentPage, let chart = model.selected {
            ZStack(alignment: .bottom) {
                ZoomableChartView(image: image, night: app.night, page: page, ownship: ownshipStore.ownship,
                                  resetKey: "\(chart.guid)#\(model.pageIndex)",
                                  follow: followAircraft, onUserPan: { followAircraft = false },
                                  annotating: app.annotating, clearToken: app.annotationClearToken)
                if app.annotating {
                    VStack {
                        AnnotateBar(onClear: { app.annotationClearToken += 1 }, onDone: { app.annotating = false })
                            .padding(.top, 12)
                        Spacer()
                    }
                }
                if let pages = model.detail?.pages, pages.count > 1 {
                    PagePicker(count: pages.count, page: Binding(get: { model.pageIndex }, set: { model.setPage($0) }))
                        .padding(.bottom, 12)
                }
                VStack(spacing: 10) {
                    chartButton(model.isSelectedPinned ? "pin.fill" : "pin", label: model.isSelectedPinned ? "Unpin from flight" : "Pin to flight",
                                active: model.isSelectedPinned) {
                        Task { await model.togglePin() }
                    }
                    if page.geoReferenced {
                        chartButton("rectangle.on.rectangle", label: "Show on map", active: false) {
                            if let overlay = model.overlayForCurrentPage() {
                                app.chartOverlay = overlay
                                app.followOwnship = false
                                app.module = .map
                            }
                        }
                        chartButton("location.north.fill", label: "Follow aircraft", active: followAircraft) {
                            followAircraft.toggle()
                        }
                        .disabled(ownshipStore.ownship.flatMap { page.position(lat: $0.lat, lon: $0.lon) } == nil)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        } else if let error = model.imageError {
            message(error, systemImage: "exclamationmark.triangle")
        } else if model.selected != nil {
            ProgressView()
        } else {
            switch model.state {
            case .idle:
                message("Choose an airport in the Flight Folder or with Search.", systemImage: "doc.text.magnifyingglass")
            case .loading:
                ProgressView()
            case let .waitingForSim(done, total):
                VStack(spacing: 14) {
                    ProgressView()
                    Text(total > 0 ? "Exporting charts from the sim… \(done)/\(total) pages" : "Waiting for the sim…")
                        .foregroundColor(theme.text)
                    Text("Keep the SimPilot Link panel open in MSFS while charts load the first time.")
                        .font(.footnote)
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
    }

    private func chartButton(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .rotationEffect(.degrees(symbol == "location.north.fill" ? 45 : 0))
                .foregroundColor(active ? Theme.ownshipBlue : theme.text)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.overlay))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
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

    #if DEBUG
    /// Why the generated test charts are showing instead of the sim's charts.
    private var testChartsReason: String {
        guard bridge.isConnected else { return "Test charts — PC bridge not connected" }
        if bridge.status?.link.connected == true {
            if case .waitingForSim = model.state { return "Test charts — loading the sim's charts…" }
            return "Test charts — sim has no charts for this airport"
        }
        return "Test charts — open SimPilot Link from the MSFS toolbar to load the sim's charts"
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { app.module = .map } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                }
                .buttonStyle(.plain)
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
                    ForEach(model.categories, id: \.self) { cat in
                        let active = (model.category ?? model.categories.first) == cat
                        Button { model.category = cat } label: {
                            Text(cat == ChartsModel.packCategory ? "★ FLIGHT" : cat)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(active ? .white : theme.text)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(Capsule().fill(active ? Theme.selectedBlue : theme.pillStrong))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 10)

            #if DEBUG
            if model.isTestCharts {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hammer.fill").font(.system(size: 11)).padding(.top, 2)
                    Text(testChartsReason).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(Theme.warnOrange)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            #endif

            Rectangle().fill(theme.separator).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleCharts) { chart in
                        let active = model.selected == chart
                        Button { model.select(chart) } label: {
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
                            .background(active ? Theme.selectedBlue.opacity(0.25) : Color.clear)
                            .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(theme.sidebar)
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
        }
        .disabled(model.runways.isEmpty)
    }
}

private struct PagePicker: View {
    @Environment(\.theme) private var theme
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
                        .background(Capsule().fill(i == page ? Theme.selectedBlue : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(theme.overlay))
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
            Button("Clear page", action: onClear).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.warnOrange)
            Button("Done", action: onDone).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.selectedBlue)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(theme.overlay))
        .overlay(Capsule().stroke(theme.separator))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

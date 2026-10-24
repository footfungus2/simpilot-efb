import SwiftUI

/// Left sidebar on the map: "Flight Folder" with the flight's airports, route, documents and notes.
struct FlightFolderView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @State private var showRoute = false
    @State private var showNotes = false
    @State private var showAddAlternate = false
    @State private var showPack = false
    @AppStorage("extraAlternates") private var extraAlternatesRaw = ""
    /// Set once the folder is on screen: rows that arrive after that (a newly loaded OFP) stagger in, while the rows
    /// already there when the folder opens simply come in with it.
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Flight Folder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.text)
                .overlay(alignment: .trailing) {
                    // Reloading a flight that's already shown: a small spinner beside the title.
                    if app.ofpLoading && app.ofp != nil {
                        ProgressView()
                            .scaleEffect(0.7)
                            .alignmentGuide(.trailing) { $0[.leading] - 8 }
                            .transition(.opacity)
                    }
                }
                .padding(.top, 18)
                .padding(.bottom, 22)

            HStack(spacing: 20) {
                GreyPillButton(title: "Edit Flight") { app.showSettings = true }
                Menu {
                    Button { Task { await app.loadOfp() } } label: { Label("Load latest SimBrief OFP", systemImage: "arrow.down.circle") }
                    Button(role: .destructive) { app.clearFlight() } label: { Label("Clear flight", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(theme.text)
                        .frame(width: 60, height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.pillStrong))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 0) {
                    separator
                    // Flight rows, skeleton rows while the first OFP loads, or the empty state; they cross-fade in place.
                    ZStack(alignment: .top) {
                        if let ofp = app.ofp {
                            flightRows(ofp)
                                .id(ofp.fetchedAt)
                                .transition(.opacity)
                        } else if app.ofpLoading {
                            loadingRows
                                .transition(.opacity)
                        } else {
                            emptyState
                                .transition(.opacity)
                        }
                    }
                    FlightChartsRow(pack: app.chartPack) { showPack = true }
                    row(icon: AnyView(Image(systemName: "doc").font(.system(size: 18))), title: "Documents", subtitle: nil) { app.showOfp = true }
                    row(icon: AnyView(Image(systemName: "mappin.and.ellipse").font(.system(size: 18))), title: "Route Notes", subtitle: nil) { showNotes = true }
                }
            }
        }
        .animation(Motion.smooth, value: app.ofp?.fetchedAt)
        .animation(Motion.smooth, value: app.ofpLoading)
        .onAppear { appeared = true }
        .background(theme.sidebar)
        .sheet(isPresented: $showRoute) { RouteSheet().environmentObject(app) }
        .sheet(isPresented: $showNotes) { RouteNotesSheet().environmentObject(app) }
        .sheet(isPresented: $showPack) { ChartPackSheet(pack: app.chartPack).environmentObject(app) }
        .sheet(isPresented: $showAddAlternate) {
            AddAlternateSheet { icao in
                var list = extraAlternates
                if !list.contains(icao) { list.append(icao) }
                withAnimation(Motion.snappy) { extraAlternatesRaw = list.joined(separator: ",") }
                app.bridge.send(requestCharts: icao)
            }
        }
        .onChange(of: app.ofp?.fetchedAt) { _ in extraAlternatesRaw = "" }
    }

    private var extraAlternates: [String] {
        extraAlternatesRaw.split(separator: ",").map(String.init)
    }

    private var separator: some View {
        Rectangle().fill(theme.separator).frame(height: 1)
    }

    /// The flight's airports and route; they stagger in when a new OFP arrives while the folder is open.
    private func flightRows(_ ofp: Ofp) -> some View {
        VStack(spacing: 0) {
            airportRow(ofp.origin, role: .origin)
                .staggeredEntrance(0, active: appeared)
            row(icon: AnyView(RouteIcon()), title: "Route", subtitle: "\(Int(ofp.distanceNm.rounded())) NM") { showRoute = true }
                .staggeredEntrance(1, active: appeared)
            airportRow(ofp.destination, role: .destination)
                .staggeredEntrance(2, active: appeared)
            ForEach(Array(ofp.alternates.enumerated()), id: \.element.icao) { i, alternate in
                airportRow(alternate, role: .alternate)
                    .staggeredEntrance(3 + i, active: appeared)
            }
            ForEach(extraAlternates, id: \.self) { icao in
                row(icon: AnyView(AirportSymbol(color: Theme.alternateMagenta)), title: icao, subtitle: "Alternate") { app.openCharts(icao) }
                    .transition(.opacity)
            }
            GreyPillButton(title: "Add Alternate") { showAddAlternate = true }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .staggeredEntrance(3 + ofp.alternates.count, active: appeared)
            separator
        }
    }

    /// Placeholder rows (airport, route, airport) while the first OFP loads.
    private var loadingRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 14) {
                    SkeletonBlock(width: 24, height: 24, cornerRadius: 12)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(width: i == 1 ? 50 : 60, height: 13)
                        SkeletonBlock(width: [150, 64, 128][i], height: 9)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: 62)
                .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the flight from SimBrief")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No flight loaded").foregroundColor(theme.textSecondary)
            GreyPillButton(title: "Load from SimBrief") { Task { await app.loadOfp() } }
                .frame(width: 200)
            if let err = app.ofpError {
                Text(err).font(.footnote).foregroundColor(Theme.warnOrange).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
    }

    enum Role { case origin, destination, alternate }

    private func airportRow(_ apt: OfpAirport, role: Role) -> some View {
        let color: Color = role == .origin ? Theme.originGreen : role == .destination ? Theme.destinationOrange : Theme.alternateMagenta
        let city = apt.name.isEmpty ? "" : apt.name
        let subtitle = apt.iata.isEmpty ? city : "\(city) - \(apt.iata)"
        return row(icon: AnyView(AirportSymbol(color: color)), title: apt.icao, subtitle: subtitle) { app.openCharts(apt.icao) }
    }

    private func row(icon: AnyView, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon.foregroundColor(theme.text).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 13)).foregroundColor(theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 16)).foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(height: subtitle == nil ? 56 : 62)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
        }
        .buttonStyle(.pressableSoft)
    }
}

/// Lido-style airport symbol: a ring with eight short ticks, tinted by role.
struct AirportSymbol: View {
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.3
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color), lineWidth: 3.2)
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                tick.addLine(to: CGPoint(x: c.x + cos(a) * r * 1.55, y: c.y + sin(a) * r * 1.55))
                ctx.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// Route icon: a small runway-like line with a waypoint triangle.
struct RouteIcon: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { ctx, size in
            var line = Path()
            line.move(to: CGPoint(x: size.width / 2, y: 2))
            line.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            ctx.stroke(line, with: .color(theme.textSecondary), lineWidth: 1.5)
            var tri = Path()
            tri.move(to: CGPoint(x: size.width / 2, y: size.height * 0.3))
            tri.addLine(to: CGPoint(x: size.width / 2 + 5, y: size.height * 0.62))
            tri.addLine(to: CGPoint(x: size.width / 2 - 5, y: size.height * 0.62))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(theme.text))
        }
        .frame(width: 20, height: 26)
    }
}

struct RouteSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                if let ofp = app.ofp {
                    Section(header: Text("Route")) {
                        Text("\(ofp.origin.icao)/\(ofp.origin.planRwy) \(ofp.route) \(ofp.destination.icao)/\(ofp.destination.planRwy)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Section(header: Text("Summary")) {
                        LabeledRow("Callsign", ofp.callsign)
                        LabeledRow("Aircraft", "\(ofp.aircraft.icao) \(ofp.aircraft.reg)")
                        LabeledRow("Distance", "\(Int(ofp.distanceNm.rounded())) NM")
                        LabeledRow("Cruise", "FL\(ofp.cruiseFl)")
                        LabeledRow("Cost index", ofp.costIndex)
                        LabeledRow("AIRAC", ofp.airac)
                    }
                    Section(header: Text("Navlog")) {
                        ForEach(Array(ofp.navlog.enumerated()), id: \.offset) { _, fix in
                            HStack {
                                Text(fix.ident).font(.system(size: 15, weight: .semibold, design: .monospaced)).frame(width: 90, alignment: .leading)
                                Text(fix.airway).font(.system(size: 13, design: .monospaced)).foregroundColor(.secondary).frame(width: 90, alignment: .leading)
                                Spacer()
                                Text(fix.altFt >= 10000 ? "FL\(Int(fix.altFt / 100))" : "\(Int(fix.altFt)) ft").monospacedDigit()
                                Text("\(Int(fix.cumNm)) NM").monospacedDigit().foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}

/// Free-text notes for the flight (clearance, ATIS, frequencies…), with the flight's route above for reference.
/// Notes save as you type and survive app restarts.
struct RouteNotesSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("routeNotes") private var notes = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                if let ofp = app.ofp {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(ofp.callsign) · \(ofp.origin.icao) → \(ofp.destination.icao) · FL\(ofp.cruiseFl) · \(Int(ofp.distanceNm.rounded())) NM")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                        Text("\(ofp.origin.icao)/\(ofp.origin.planRwy) \(ofp.route) \(ofp.destination.icao)/\(ofp.destination.planRwy)")
                            .font(.system(size: 14, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                }
                ZStack(alignment: .topLeading) {
                    NotesTextView(text: $notes)
                    if notes.isEmpty {
                        Text("Tap here to write notes: clearance, ATIS, frequencies, reminders…")
                            .font(.system(size: 17)).foregroundColor(Color(.placeholderText))
                            .padding(.horizontal, 17).padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
            }
            .padding(16)
            .navigationTitle("Route Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { notes = "" }.disabled(notes.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// UITextView wrapper: transparent background (TextEditor's can't be changed on iOS 15) and the keyboard comes up
/// as soon as the notes open.
private struct NotesTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .systemFont(ofSize: 17)
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.delegate = context.coordinator
        view.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { _text = text }
        func textViewDidChange(_ textView: UITextView) { text = textView.text }
    }
}

struct AddAlternateSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var icao = ""
    let onAdd: (String) -> Void

    var body: some View {
        NavigationView {
            Form {
                TextField("ICAO code", text: $icao)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .onSubmit(add)
            }
            .navigationTitle("Add Alternate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add).disabled(valid == nil) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var valid: String? {
        let s = icao.trimmingCharacters(in: .whitespaces).uppercased()
        return s.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil ? s : nil
    }

    private func add() {
        guard let v = valid else { return }
        onAdd(v)
        presentationMode.wrappedValue.dismiss()
    }
}

/// Flight Folder row for the pinned chart pack.
private struct FlightChartsRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject var pack: ChartPack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "pin").font(.system(size: 18)).foregroundColor(theme.text).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flight Charts").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                    Text(pack.items.isEmpty ? "Pin charts from the chart viewer" : "\(pack.items.count) pinned · available offline")
                        .font(.system(size: 13)).foregroundColor(theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 16)).foregroundColor(theme.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .contentShape(Rectangle())
            .overlay(Rectangle().fill(theme.separator).frame(height: 1), alignment: .bottom)
        }
        .buttonStyle(.pressableSoft)
    }
}

/// The flight's chart pack: open, reorder (drag), or remove pinned charts.
struct ChartPackSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var pack: ChartPack

    var body: some View {
        NavigationView {
            List {
                if pack.items.isEmpty {
                    Text("Open a chart and tap the pin button to add it here. Pinned charts are kept on the iPad and work without the sim or internet.")
                        .foregroundColor(.secondary)
                }
                ForEach(pack.items) { item in
                    Button {
                        open(item)
                    } label: {
                        HStack(spacing: 12) {
                            Text(item.detail.chart.type)
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 22)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.selectedBlue))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.detail.chart.name).font(.system(size: 16, weight: .semibold))
                                Text(item.icao).font(.system(size: 13)).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .onMove { pack.move(from: $0, to: $1) }
                .onDelete { offsets in offsets.map { pack.items[$0].detail.chart.guid }.forEach(pack.remove) }
            }
            .navigationTitle("Flight Charts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .alert("Flight Charts", isPresented: Binding(get: { pack.error != nil }, set: { if !$0 { pack.error = nil } })) {
            Button("OK", role: .cancel) { pack.error = nil }
        } message: {
            Text(pack.error ?? "")
        }
    }

    private func open(_ item: ChartPack.Item) {
        app.chartsModel.category = ChartsModel.packCategory
        app.chartsAirport = item.icao
        app.module = .charts
        if let meta = app.chartsModel.packCharts.first(where: { $0.guid == item.detail.chart.guid }) {
            app.chartsModel.select(meta)
        }
        presentationMode.wrappedValue.dismiss()
    }
}

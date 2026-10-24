import SwiftUI

/// The top bar's 文A button: ATIS & weather for the flight's airports, the nearest airport and any ICAO.
/// VATSIM ATIS when online, METAR and TAF raw or in plain language ("Decoded"), the TAF group in force at the
/// weather time highlighted. Refreshes every 5 minutes while open.
struct WeatherBriefingView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var vatsim: VatsimStore
    @Environment(\.theme) private var theme
    @AppStorage(WeatherDecoder.decodedSettingKey) private var decoded = false
    @SceneStorage("wxBriefingAirport") private var selected = ""
    @SceneStorage("wxBriefingLookups") private var lookups = ""
    @State private var query = ""
    @State private var queryInvalid = false
    @State private var nearest: String?
    @State private var weather: AirportWeather?
    @State private var loadingIcao: String?
    @State private var error: String?
    @State private var vatsimChecked = false
    @Namespace private var chipSelection

    static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chips
            Divider()
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width, height: 600)
        .task { await prepare() }
        .task(id: selected) { await autoRefresh() }
    }

    // MARK: Header and airport chips

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ATIS & Weather").font(.headline)
                Text(weatherTimeText).font(.caption).foregroundColor(app.wxOffsetHours > 0 ? theme.accentColor : .secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { decoded }, set: { on in withAnimation(Motion.smooth) { decoded = on } })) {
                Text("Decoded").font(.subheadline)
            }
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .fixedSize()
            .accessibilityHint("Shows METAR and TAF in plain language")
            Button(action: refresh) {
                Group {
                    if loadingIcao != nil { ProgressView() } else { Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold)) }
                }
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.secondary.opacity(0.14)))
            }
            .buttonStyle(.pressable)
            .disabled(selected.isEmpty || loadingIcao != nil)
            .environment(\.pressableDisabledOpacity, loadingIcao != nil ? 1 : 0.4)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private struct Chip: Identifiable {
        let icao: String
        let role: String
        let color: Color
        var id: String { icao }
    }

    private var chipList: [Chip] {
        var out: [Chip] = []
        func add(_ icao: String, _ role: String, _ color: Color) {
            guard !icao.isEmpty, !out.contains(where: { $0.icao == icao }) else { return }
            out.append(Chip(icao: icao, role: role, color: color))
        }
        if let ofp = app.ofp {
            add(ofp.origin.icao, "DEP", Theme.originGreen)
            add(ofp.destination.icao, "DEST", Theme.destinationOrange)
            ofp.alternates.forEach { add($0.icao, "ALTN", Theme.alternateMagenta) }
        }
        if let nearest { add(nearest, "NEAR", Theme.ownshipBlue) }
        lookupList.forEach { add($0, "", .secondary) }
        return out
    }

    private var lookupList: [String] { lookups.split(separator: ",").map(String.init) }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chipList) { chip in
                    Button { select(chip.icao) } label: { chipLabel(chip) }
                        .buttonStyle(.pressableSoft)
                }
                lookupField
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func chipLabel(_ chip: Chip) -> some View {
        let isSelected = chip.icao == selected
        return HStack(spacing: 6) {
            if !chip.role.isEmpty {
                Text(chip.role)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isSelected ? .white : chip.color)
            }
            Text(chip.icao).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .foregroundColor(isSelected ? .white : .primary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.14))
                if isSelected {
                    Capsule().fill(theme.accentColor).matchedGeometryEffect(id: "selection", in: chipSelection)
                }
            }
        )
        .accessibilityLabel("\(chip.icao)\(chip.role.isEmpty ? "" : ", \(chip.role)")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var lookupField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            TextField("ICAO", text: $query)
                .font(.system(size: 14, weight: .semibold))
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .onSubmit(lookUp)
                .onChange(of: query) { _ in if queryInvalid { withAnimation(Motion.smooth) { queryInvalid = false } } }
                .frame(width: 58)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
        .overlay(Capsule().stroke(queryInvalid ? Color.red : .clear, lineWidth: 1.2))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if selected.isEmpty {
            emptyState
        } else if let weather, weather.icao == selected {
            details(weather)
                .transition(.opacity)
        } else if let error {
            failure(error)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                SkeletonBlock(width: 180, height: 20)
                SkeletonBlock(height: 70)
                SkeletonBlock(height: 100)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading weather for \(selected)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud.sun").font(.system(size: 34)).foregroundColor(.secondary)
            Text("Type an airport ICAO above").font(.headline)
            Text("Load a SimBrief flight and its departure, destination and alternates appear here; with the sim connected, also the nearest airport.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(.horizontal, 24)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.icloud").font(.system(size: 30)).foregroundColor(Theme.warnOrange)
            Text("Weather couldn't be loaded").font(.headline)
            Text(message).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("Try again", action: refresh)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func details(_ w: AirportWeather) -> some View {
        let imperial = WeatherDecoder.usesImperial(w.icao)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(w.icao).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(airportName(w)).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }

            section("ATIS", trailing: atisTrailing) { atis(w.icao) }

            section("METAR", trailing: metarTrailing(w)) {
                if let m = w.metar {
                    if decoded { MetarDecodedRows(metar: m, imperial: imperial) } else { RawWeatherText(text: m.raw) }
                } else {
                    note(w.metarError ?? "No METAR available for \(w.icao).", warning: w.metarError != nil)
                }
            }

            section("TAF", trailing: tafTrailing(w)) {
                if let t = w.taf {
                    TafLinesView(taf: t, time: app.weatherTime, decoded: decoded, imperial: imperial)
                } else {
                    note(w.tafError ?? "No TAF issued for \(w.icao).", warning: w.tafError != nil)
                }
            }
        }
        .animation(Motion.smooth, value: decoded)
    }

    // MARK: ATIS (VATSIM)

    private var atisTrailing: AnyView? {
        AnyView(Text("VATSIM").font(.caption2.weight(.semibold)).foregroundColor(.secondary))
    }

    @ViewBuilder private func atis(_ icao: String) -> some View {
        let stations = (vatsim.feed?.atis ?? [])
            .filter { $0.callsign.uppercased().hasPrefix("\(icao)_") }
            .sorted { $0.callsign < $1.callsign }
        if stations.isEmpty {
            if vatsim.feed == nil && !vatsimChecked {
                HStack(spacing: 8) { ProgressView(); Text("Checking VATSIM…").foregroundColor(.secondary) }.font(.subheadline)
            } else if vatsim.feed == nil {
                note(vatsim.error ?? "VATSIM data unavailable.", warning: true)
            } else {
                note("No VATSIM ATIS online for \(icao).", warning: false)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(stations, id: \.callsign) { AtisBlock(controller: $0) }
            }
        }
    }

    // MARK: Section helpers

    private func metarTrailing(_ w: AirportWeather) -> AnyView? {
        guard let m = w.metar else { return nil }
        return AnyView(HStack(spacing: 8) {
            WxCategoryChip(category: m.category)
            if let observed = m.observed { ObservationAge(date: observed) }
        })
    }

    private func tafTrailing(_ w: AirportWeather) -> AnyView? {
        guard let t = w.taf else { return nil }
        let issued = t.issued.map { "Issued \(WeatherDecoder.time($0)) · " } ?? ""
        return AnyView(Text("\(issued)valid \(WeatherDecoder.time(t.validFrom)) – \(WeatherDecoder.time(t.validTo))")
            .font(.caption).foregroundColor(.secondary).lineLimit(1))
    }

    private func section<Content: View>(_ title: String, trailing: AnyView?, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Spacer(minLength: 8)
                trailing
            }
            body()
        }
    }

    private func note(_ text: String, warning: Bool) -> some View {
        HStack(spacing: 6) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warnOrange) }
            Text(text).foregroundColor(.secondary)
        }
        .font(.subheadline)
    }

    private func airportName(_ w: AirportWeather) -> String {
        if let ofpName = app.flightAirports.first(where: { $0.icao == w.icao })?.name, !ofpName.isEmpty { return ofpName }
        if let info = WeatherAirports.all[w.icao], !info.name.isEmpty { return info.name }
        // AWC names read "London/Stansted Arpt, EN, GB".
        return w.name.map { String($0.split(separator: ",").first ?? "") } ?? ""
    }

    // MARK: Weather time

    private var weatherTimeText: String {
        guard app.wxOffsetHours > 0 else { return "Now · METAR and the TAF group in force" }
        return "Weather time \(WeatherDecoder.time(app.weatherTime)) (+\(app.wxOffsetHours) h) · TAF group highlighted"
    }

    // MARK: Actions

    private func select(_ icao: String) {
        guard icao != selected else { return }
        withAnimation(Motion.snappy) { selected = icao }
        error = nil
    }

    private func lookUp() {
        let icao = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard WeatherService.isValid(icao) else {
            withAnimation(Motion.smooth) { queryInvalid = true }
            return
        }
        if !chipList.contains(where: { $0.icao == icao }) {
            lookups = (lookupList.filter { $0 != icao }.suffix(4) + [icao]).joined(separator: ",")
        }
        query = ""
        select(icao)
    }

    private func prepare() async {
        if let o = app.bridge.ownship.ownship, let icao = AirportIndex.nearest(to: o.coordinate, withinKm: 100) { nearest = icao }
        if selected.isEmpty || !chipList.contains(where: { $0.icao == selected }) {
            selected = defaultSelection ?? ""
        }
        if vatsim.feed == nil { await vatsim.refresh() }
        vatsimChecked = true
    }

    /// The airport the aircraft is at, the destination once airborne, else the departure.
    private var defaultSelection: String? {
        let flight = app.flightAirports.map(\.icao)
        if let o = app.bridge.ownship.ownship {
            if let nearest, flight.contains(nearest) { return nearest }
            if !o.onGround, let dest = app.ofp?.destination.icao { return dest }
            return nearest ?? flight.first
        }
        return flight.first ?? lookupList.last
    }

    /// Refresh button: weather now, and the VATSIM feed when the VATSIM layer isn't polling it anyway.
    private func refresh() {
        Task { await load(force: true) }
        if !vatsim.enabled { Task { await vatsim.refresh() } }
    }

    private func autoRefresh() async {
        guard !selected.isEmpty else { return }
        while !Task.isCancelled {
            await load(force: false)
            try? await Task.sleep(nanoseconds: 300_000_000_000)
        }
    }

    private func load(force: Bool) async {
        let icao = selected
        guard !icao.isEmpty else { return }
        loadingIcao = icao
        defer { if loadingIcao == icao { loadingIcao = nil } }
        do {
            let result = try await WeatherService.airport(icao, force: force)
            guard icao == selected else { return }
            withAnimation(Motion.smooth) {
                weather = result
                error = nil
            }
        } catch {
            guard icao == selected, !Task.isCancelled else { return }
            withAnimation(Motion.smooth) { self.error = WeatherService.message(for: error) }
        }
    }
}

// MARK: - Shared weather views (briefing and airport card)

/// "Good" / "Marginal" / "Poor" in the map indicator's colour.
struct WxCategoryChip: View {
    let category: WxCategory

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: category.hex)).frame(width: 7, height: 7)
            Text(category.title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(Color(hex: category.hex))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color(hex: category.hex).opacity(0.16)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Conditions \(category.title)")
    }
}

/// "12 min ago", orange once a METAR is over an hour old.
struct ObservationAge: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            let minutes = max(0, Int(context.date.timeIntervalSince(date) / 60))
            Text(minutes < 1 ? "Just now" : minutes < 120 ? "\(minutes) min ago" : "\(minutes / 60) h ago")
                .font(.caption.monospacedDigit())
                .foregroundColor(minutes > 60 ? Theme.warnOrange : .secondary)
        }
    }
}

/// Raw METAR text in a quiet inset.
struct RawWeatherText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }
}

/// Plain-language METAR, one element per row.
struct MetarDecodedRows: View {
    let metar: MetarReport
    let imperial: Bool

    var body: some View {
        let c = metar.conditions
        let rows: [(String, String)] = [
            ("Wind", WeatherDecoder.wind(c)),
            ("Visibility", WeatherDecoder.visibility(c, imperial: imperial)),
            ("Weather", WeatherDecoder.weather(c.weather)),
            ("Clouds", WeatherDecoder.clouds(c)),
            ("Temperature", WeatherDecoder.temperature(metar)),
            ("QNH", WeatherDecoder.pressure(metar.altimeterHpa, imperial: imperial)),
        ].compactMap { label, value in value.map { (label, $0) } }
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.0) { label, value in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).frame(width: 84, alignment: .leading)
                    Text(value).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }
}

/// TAF groups on separate lines, raw or decoded; groups in force at `time` are highlighted.
struct TafLinesView: View {
    @Environment(\.theme) private var theme
    let taf: TafReport
    let time: Date
    var decoded = false
    var imperial = false
    var compact = false

    var body: some View {
        let active = taf.forecast(at: time)?.activeGroups ?? []
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            if decoded {
                ForEach(decodedOrder, id: \.self) { i in
                    decodedRow(taf.groups[i], active: active.contains(i))
                }
            } else {
                let lines = TafText.lines(taf.raw)
                let activeLines = rawLines(active, count: lines.count)
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    row(active: activeLines.contains(i)) {
                        Text(line).font(.system(size: compact ? 11.5 : 13, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if time < taf.validFrom || time >= taf.validTo {
                Text("The weather time is outside this TAF's validity.").font(.caption).foregroundColor(Theme.warnOrange).padding(.top, 2)
            }
        }
        .textSelection(.enabled)
    }

    /// Groups in reading order (raw text order when known).
    private var decodedOrder: [Int] {
        taf.groups.indices.sorted { (taf.groups[$0].rawIndex ?? $0) < (taf.groups[$1].rawIndex ?? $1) }
    }

    /// Raw lines for the active groups; only when every group maps onto exactly one line.
    private func rawLines(_ active: Set<Int>, count: Int) -> Set<Int> {
        guard taf.groups.count == count, taf.groups.allSatisfy({ $0.rawIndex != nil }) else { return [] }
        return Set(active.compactMap { taf.groups[$0].rawIndex })
    }

    private func decodedRow(_ g: TafGroup, active: Bool) -> some View {
        row(active: active) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WeatherDecoder.title(g)).font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundColor(active ? theme.accentColor : .secondary)
                Text(WeatherDecoder.summary(g.conditions, imperial: imperial)).font(.system(size: compact ? 12 : 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Content: View>(active: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(active ? theme.accentColor : Color.clear).frame(width: 3)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, compact ? 3 : 5)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? theme.accentColor.opacity(0.14) : Color.clear))
        .opacity(active ? 1 : 0.8)
        .animation(Motion.smooth, value: active)
    }
}

enum TafText {
    /// A raw TAF split into its groups: header with the base forecast, then one line per FM/BECMG/TEMPO/PROB group.
    static func lines(_ raw: String) -> [String] {
        var lines: [[Substring]] = []
        var previous: Substring?
        for token in raw.split(whereSeparator: \.isWhitespace) {
            let fromGroup = token.hasPrefix("FM") && token.count >= 8 && token.dropFirst(2).allSatisfy(\.isNumber)
            let probability = token.hasPrefix("PROB") && token.count == 6
            let tempo = (token == "TEMPO" || token == "INTER") && !(previous?.hasPrefix("PROB") ?? false)
            if lines.isEmpty || fromGroup || probability || tempo || token == "BECMG" {
                lines.append([token])
            } else {
                lines[lines.count - 1].append(token)
            }
            previous = token
        }
        return lines.map { $0.joined(separator: " ") }
    }
}

/// One VATSIM ATIS: letter, frequency, text.
private struct AtisBlock: View {
    let controller: VatsimController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(letter ?? "–")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: 0x1A1A1A))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(VatsimInfoCard.atisYellow))
                    .accessibilityLabel(letter.map { "Information \($0)" } ?? "ATIS")
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.callsign).font(.system(size: 14, weight: .semibold))
                    Text("Online \(controller.onlineFor)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(controller.frequency).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("MHz").font(.caption).foregroundColor(.secondary)
            }
            if !text.isEmpty {
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private var text: String {
        (controller.text_atis ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The feed's ATIS code, else "INFORMATION K" / "INFO K" in the text.
    private var letter: String? {
        if let code = controller.atis_code?.trimmingCharacters(in: .whitespaces), code.count == 1 { return code.uppercased() }
        let pattern = try? NSRegularExpression(pattern: #"\bINFO(?:RMATION)?\s+([A-Z])\b"#)
        let upper = text.uppercased()
        guard let m = pattern?.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)),
              let r = Range(m.range(at: 1), in: upper) else { return nil }
        return String(upper[r])
    }
}

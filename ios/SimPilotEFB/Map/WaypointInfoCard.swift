import CoreLocation
import SwiftUI

/// Details for a tapped route waypoint, navaid or airport (airports and WX indicators also show METAR and TAF).
struct WaypointInfoCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    let pick: MapPick
    let ownship: Ownship?
    let onClose: () -> Void
    @State private var weather: AirportWeather?
    @State private var weatherError: String?
    @State private var weatherLoading = false
    /// The airport the latest weather request is for (a slower, older request must not overwrite it).
    @State private var weatherRequest = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 13)).foregroundColor(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(theme.textSecondary)
                        .frame(width: 28, height: 28).background(Circle().fill(theme.pill))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(theme.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
                    ForEach(rows, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
                            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(theme.text)
                        }
                    }
                }
                if pick.kind == .airport {
                    AirportWeatherSection(icao: icao, weather: weather, error: weatherError, loading: weatherLoading) {
                        Task { await loadWeather(force: true) }
                    }
                }
                Text(Self.dms(pick.coordinate)).font(.system(size: 12)).monospacedDigit().foregroundColor(theme.textSecondary)
            }
            .padding(16)
        }
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .task(id: pick.id) { await loadWeather(force: false) }
    }

    // MARK: Content per kind

    private var fix: OfpFix? {
        guard pick.kind == .fix, let i = Int(pick.id), let navlog = app.ofp?.navlog, navlog.indices.contains(i) else { return nil }
        return navlog[i]
    }

    private var a: [String: String] { pick.attributes }

    private var icao: String { a["icao"] ?? pick.id }

    private var title: String {
        switch pick.kind {
        case .fix: return fix?.ident ?? a["ident"] ?? "Waypoint"
        case .navaid: return "\(a["id"] ?? "") · \(a["name"] ?? "")"
        case .airport:
            // AWC names read "Corvallis Muni, OR, US" (stations that aren't in the airport list).
            let awcName = weather?.icao == icao ? weather?.name.flatMap { $0.split(separator: ",").first.map(String.init) } : nil
            return "\(icao) · \(a["name"] ?? VatsimReference.shared.airports[icao]?.name ?? awcName ?? "")"
        }
    }

    private var subtitle: String {
        switch pick.kind {
        case .fix:
            guard let f = fix else { return "Route waypoint" }
            let kind = ["wpt": "Waypoint", "vor": "VOR", "ndb": "NDB", "ltlg": "Lat/long point"][f.type] ?? f.type.uppercased()
            return [kind, f.name == f.ident ? nil : f.name.capitalized].compactMap { $0 }.joined(separator: " · ")
        case .navaid: return [a["type"], a["cc"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case .airport: return [a["city"], a["iata"].map { $0.isEmpty ? nil : "IATA \($0)" } ?? nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder private var badge: some View {
        let (symbol, color): (String, Color) = {
            switch pick.kind {
            case .fix: return ("triangle", Theme.route)
            case .navaid: return (a["kind"] == "ndb" ? "circle.dotted" : "hexagon", a["kind"] == "ndb" ? Color(hex: 0xC467C9) : Color(hex: 0x5AB0E8))
            case .airport: return ("airplane", Theme.ownshipBlue)
            }
        }()
        Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 8).fill(color))
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = []
        switch pick.kind {
        case .fix:
            if let f = fix {
                if !f.airway.isEmpty { out.append(("Via", f.airway)) }
                out.append(("Planned alt", f.altFt >= 10_000 ? "FL\(Int((f.altFt / 100).rounded()))" : "\(Int(f.altFt)) ft"))
                out.append(("Leg", String(format: "%.0f NM", f.legNm)))
                out.append(("From departure", String(format: "%.0f NM", f.cumNm)))
                if !f.frequency.isEmpty { out.append(("Frequency", f.frequency)) }
                if let ofp = app.ofp, let o = ownship, let along = RouteProgress.alongTrackNm(ofp: ofp, o) {
                    let togo = f.cumNm - along
                    if togo > 0 {
                        out.append(("To go", String(format: "%.0f NM", togo)))
                        if o.gsKt > 50 { out.append(("ETA", Self.utc(Date().addingTimeInterval(togo / o.gsKt * 3600)))) }
                    } else {
                        out.append(("Status", "Passed"))
                    }
                }
            }
        case .navaid:
            if let f = a["freq"], !f.isEmpty { out.append(("Frequency", a["kind"] == "ndb" ? "\(f) kHz" : "\(f) MHz")) }
            if let ch = a["ch"], !ch.isEmpty { out.append(("DME channel", ch)) }
            if let e = a["elev"], e != "<null>", !e.isEmpty { out.append(("Elevation", "\(e) ft")) }
            if let v = a["var"], let d = Double(v) { out.append(("Mag var", String(format: "%.1f° %@", abs(d), d < 0 ? "W" : "E"))) }
            if let apt = a["apt"], !apt.isEmpty { out.append(("Airport", apt)) }
        case .airport:
            if let e = a["elev"], e != "<null>", !e.isEmpty { out.append(("Elevation", "\(e) ft")) }
            if let role = a["role"] { out.append(("Flight", role.capitalized)) }
        }
        if let o = ownship {
            let from = CLLocation(latitude: o.lat, longitude: o.lon)
            let to = CLLocation(latitude: pick.coordinate.latitude, longitude: pick.coordinate.longitude)
            out.append(("Distance", String(format: "%.0f NM", from.distance(from: to) / 1852)))
            out.append(("Bearing", String(format: "%03.0f° T", RunwayAwareness.bearing(o.coordinate, pick.coordinate))))
        }
        return out
    }

    private func loadWeather(force: Bool) async {
        guard pick.kind == .airport else { return }
        let icao = icao
        weatherRequest = icao
        if weather?.icao != icao {
            weather = nil
            weatherError = nil
        }
        weatherLoading = true
        do {
            let result = try await WeatherService.airport(icao, force: force)
            guard weatherRequest == icao else { return }
            withAnimation(Motion.smooth) {
                weather = result
                weatherError = nil
                weatherLoading = false
            }
        } catch {
            guard weatherRequest == icao else { return }
            weatherLoading = false
            guard !Task.isCancelled else { return }
            withAnimation(Motion.smooth) { weatherError = WeatherService.message(for: error) }
        }
    }

    static func dms(_ c: CLLocationCoordinate2D) -> String {
        func f(_ v: Double, _ pos: String, _ neg: String, _ w: Int) -> String {
            let d = abs(v), deg = Int(d), min = (d - Double(deg)) * 60
            return String(format: "%@%0\(w)d°%06.3f'", v >= 0 ? pos : neg, deg, min)
        }
        return "\(f(c.latitude, "N", "S", 2))  \(f(c.longitude, "E", "W", 3))"
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm'Z'"
        return f.string(from: d)
    }
}

/// METAR and TAF on the airport card, raw or decoded (the briefing's Decoded switch), with the TAF group at the
/// weather time highlighted.
private struct AirportWeatherSection: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @AppStorage(WeatherDecoder.decodedSettingKey) private var decoded = false
    let icao: String
    let weather: AirportWeather?
    let error: String?
    let loading: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("WEATHER").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
                if let m = weather?.metar {
                    WxCategoryChip(category: m.category)
                    if let observed = m.observed { ObservationAge(date: observed) }
                }
                Spacer(minLength: 4)
                if weather?.metar != nil || weather?.taf != nil {
                    Picker("Format", selection: Binding(get: { decoded }, set: { on in withAnimation(Motion.smooth) { decoded = on } })) {
                        Text("Raw").tag(false)
                        Text("Decoded").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 136)
                }
            }
            content
        }
        .animation(Motion.smooth, value: decoded)
    }

    @ViewBuilder private var content: some View {
        if let w = weather, w.icao == icao {
            FittingScrollView(maxHeight: 300) { reports(w) }
                .transition(.opacity)
        } else if let error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warnOrange)
                Text(error).foregroundColor(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Retry", action: onRetry).font(.system(size: 13, weight: .semibold)).disabled(loading)
            }
            .font(.system(size: 13))
        } else {
            VStack(alignment: .leading, spacing: 7) {
                SkeletonBlock(height: 12)
                SkeletonBlock(width: 220, height: 12)
                SkeletonBlock(width: 280, height: 12)
            }
            .padding(.vertical, 2)
            .accessibilityLabel("Loading weather")
        }
    }

    private func reports(_ w: AirportWeather) -> some View {
        let imperial = WeatherDecoder.usesImperial(w.icao)
        return VStack(alignment: .leading, spacing: 10) {
            if let m = w.metar {
                if decoded { MetarDecodedRows(metar: m, imperial: imperial) } else { RawWeatherText(text: m.raw, size: 12) }
            } else {
                note(w.metarError ?? "No METAR available.", warning: w.metarError != nil)
            }
            if let t = w.taf {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("TAF").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
                        Text("valid \(WeatherDecoder.time(t.validFrom)) – \(WeatherDecoder.time(t.validTo))")
                            .font(.system(size: 11)).foregroundColor(theme.textSecondary)
                        Spacer(minLength: 4)
                        if app.wxOffsetHours > 0 {
                            Text("at \(WeatherDecoder.time(app.weatherTime))").font(.system(size: 11, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                        }
                    }
                    TafLinesView(taf: t, time: app.weatherTime, decoded: decoded, imperial: imperial, compact: true)
                }
            } else {
                note(w.tafError ?? "No TAF issued.", warning: w.tafError != nil)
            }
        }
    }

    private func note(_ text: String, warning: Bool) -> some View {
        HStack(spacing: 6) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warnOrange) }
            Text(text).foregroundColor(theme.textSecondary)
        }
        .font(.system(size: 13))
    }
}

/// A vertical ScrollView that is only as tall as its content, up to `maxHeight`.
struct FittingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: contentHeight > maxHeight) {
            content.background(GeometryReader { g in
                Color.clear.preference(key: FittingHeightKey.self, value: g.size.height)
            })
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(FittingHeightKey.self) { contentHeight = $0 }
    }
}

private struct FittingHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

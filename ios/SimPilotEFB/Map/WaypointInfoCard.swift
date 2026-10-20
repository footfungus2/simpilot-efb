import CoreLocation
import SwiftUI

/// Details for a tapped route waypoint, navaid or airport.
struct WaypointInfoCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    let pick: MapPick
    let ownship: Ownship?
    let onClose: () -> Void
    @State private var metar: String?

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
                .buttonStyle(.plain)
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
                if let metar {
                    Text(metar).font(.system(size: 12, design: .monospaced)).foregroundColor(theme.text.opacity(0.85))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                }
                Text(Self.dms(pick.coordinate)).font(.system(size: 12)).monospacedDigit().foregroundColor(theme.textSecondary)
            }
            .padding(16)
        }
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .task(id: pick.id) { await loadMetar() }
    }

    // MARK: Content per kind

    private var fix: OfpFix? {
        guard pick.kind == .fix, let i = Int(pick.id), let navlog = app.ofp?.navlog, navlog.indices.contains(i) else { return nil }
        return navlog[i]
    }

    private var a: [String: String] { pick.attributes }

    private var title: String {
        switch pick.kind {
        case .fix: return fix?.ident ?? a["ident"] ?? "Waypoint"
        case .navaid: return "\(a["id"] ?? "") · \(a["name"] ?? "")"
        case .airport:
            let icao = a["icao"] ?? pick.id
            return "\(icao) · \(a["name"] ?? VatsimReference.shared.airports[icao]?.name ?? "")"
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

    private func loadMetar() async {
        metar = nil
        guard pick.kind == .airport else { return }
        let icao = a["icao"] ?? pick.id
        metar = await WeatherService.metar(icao: icao)
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

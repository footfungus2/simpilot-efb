import SwiftUI

/// One station's ATIS from the VATSIM data feed.
struct AtisInfo: Identifiable, Equatable {
    var id: String { callsign }
    var callsign: String
    var frequency: String
    var code: String?
    var text: String
}

enum AtisService {
    private struct Feed: Decodable {
        struct Entry: Decodable {
            var callsign: String
            var frequency: String
            var atis_code: String?
            var text_atis: [String]?
        }
        var atis: [Entry]?
    }

    /// ATIS stations online for the given airports, keyed by ICAO ("EGSS_ATIS", "EGLL_A_ATIS" → "EGSS", "EGLL").
    static func fetch(airports: [String]) async throws -> [String: [AtisInfo]] {
        var request = URLRequest(url: URL(string: "https://data.vatsim.net/v3/vatsim-data.json")!)
        request.setValue("SimPilotEFB/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let feed = try await Task.detached(priority: .utility) { try JSONDecoder().decode(Feed.self, from: data) }.value
        let wanted = Set(airports.map { $0.uppercased() })
        var result: [String: [AtisInfo]] = [:]
        for entry in feed.atis ?? [] {
            let icao = entry.callsign.uppercased().split(separator: "_").first.map(String.init) ?? ""
            guard wanted.contains(icao) else { continue }
            let text = (entry.text_atis ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            result[icao, default: []].append(AtisInfo(callsign: entry.callsign, frequency: entry.frequency, code: entry.atis_code, text: text))
        }
        return result
    }
}

/// Departure and arrival (and alternates) on one screen: the runway and procedures from the OFP, live QNH and
/// wind, the ATIS if someone is online, the minima you enter, and a shortcut to the airport's charts.
struct BriefingPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var store: FlightToolsStore
    var compact: Bool

    @State private var weather: [String: AirportWeather] = [:]
    @State private var atis: [String: [AtisInfo]] = [:]
    @State private var atisError: String?
    @State private var loading = false
    @State private var updated: Date?

    private var stations: [(role: String, airport: OfpAirport)] {
        guard let ofp = app.ofp else { return [] }
        return [("Departure", ofp.origin), ("Arrival", ofp.destination)] + ofp.alternates.map { ("Alternate", $0) }
    }

    var body: some View {
        if let ofp = app.ofp {
            VStack(spacing: 16) {
                HStack {
                    Text(updated.map { "Weather and ATIS updated \(FlightFormat.time($0))" } ?? (loading ? "Loading…" : ""))
                        .font(.system(size: 13)).foregroundColor(theme.textSecondary)
                    Spacer()
                    ActionButton(label: "Refresh", systemImage: "arrow.clockwise", pending: loading) { Task { await load() } }
                }
                let main = stations.filter { $0.role != "Alternate" }
                AdaptiveStack(compact: compact) {
                    ForEach(main, id: \.airport.icao) { station in card(station.role, station.airport) }
                }
                ForEach(stations.filter { $0.role == "Alternate" }, id: \.airport.icao) { station in card(station.role, station.airport) }
            }
            .task(id: ofp.fetchedAt) { await load() }
        } else {
            emptyState
        }
    }

    private func card(_ role: String, _ airport: OfpAirport) -> some View {
        AirportBriefCard(role: role, airport: airport, runway: app.plannedRunway(at: airport.icao), procedures: Array(app.flightProcedures(at: airport.icao)).sorted(),
                         weather: weather[airport.icao], atis: atis[airport.icao], atisError: atisError, loading: loading,
                         minima: Binding(get: { store.minima(flight: app.flightKey, icao: airport.icao) },
                                         set: { store.setMinima($0, flight: app.flightKey, icao: airport.icao) }),
                         openCharts: { app.openCharts(airport.icao) })
    }

    private var emptyState: some View {
        Card(title: "Briefing") {
            VStack(alignment: .leading, spacing: 8) {
                Text("No flight loaded").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                Text("Load your SimBrief flight in the Flight Folder (map screen, sidebar) and the departure and arrival briefing appears here.")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        let icaos = stations.map(\.airport.icao)
        guard !icaos.isEmpty else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (String, AirportWeather?).self) { group in
            for icao in icaos { group.addTask { (icao, try? await WeatherService.airport(icao, force: true)) } }
            for await (icao, result) in group { if let result { weather[icao] = result } }
        }
        do {
            atis = try await AtisService.fetch(airports: icaos)
            atisError = nil
        } catch {
            atisError = "ATIS unavailable (no connection to VATSIM)"
        }
        updated = Date()
    }
}

private struct AirportBriefCard: View {
    @Environment(\.theme) private var theme
    let role: String
    let airport: OfpAirport
    let runway: String
    let procedures: [String]
    let weather: AirportWeather?
    let atis: [AtisInfo]?
    let atisError: String?
    let loading: Bool
    @Binding var minima: Minima
    let openCharts: () -> Void

    private var metar: MetarReport? { weather?.metar }

    var body: some View {
        Card(title: "\(role) · \(airport.icao)", accessory: {
            Text(airport.name).font(.system(size: 12)).foregroundColor(theme.textSecondary).lineLimit(1)
        }, content: {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
                    Fact(label: "Runway", value: runway.isEmpty ? "–" : runway)
                    if role != "Alternate" {
                        Fact(label: role == "Departure" ? "SID" : "STAR", value: procedures.isEmpty ? "–" : procedures.joined(separator: ", "))
                    }
                    Fact(label: "QNH", value: qnh)
                    Fact(label: "Wind", value: wind)
                    Fact(label: "Ceiling", value: ceiling)
                    Fact(label: "Elevation", value: "\(Int(airport.elevFt.rounded())) ft")
                }
                if let raw = metar?.raw ?? nonEmpty(airport.metar) {
                    Text(raw).font(.system(size: 13, design: .monospaced)).foregroundColor(theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                atisSection
                minimaSection
                GreyPillButton(title: "Charts for \(airport.icao)", action: openCharts).frame(height: 34)
            }
        })
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private var qnh: String {
        guard let hpa = metar?.altimeterHpa else { return loading ? "…" : "–" }
        return String(format: "%.0f hPa · %.2f inHg", hpa, hpa / 33.8639)
    }

    private var wind: String {
        guard let c = metar?.conditions else { return loading ? "…" : "–" }
        guard let speed = c.windSpeedKt else { return "–" }
        if speed == 0 { return "Calm" }
        let direction = c.windVariable ? "VRB" : c.windDirDeg.map { String(format: "%03d°", $0) } ?? "–"
        return "\(direction) \(speed) kt" + (c.windGustKt.map { " G\($0)" } ?? "")
    }

    private var ceiling: String {
        guard let c = metar?.conditions else { return loading ? "…" : "–" }
        return c.ceilingFt.map { "\(Int($0)) ft" } ?? "None"
    }

    @ViewBuilder private var atisSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATIS (VATSIM)").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.5)
            if let atis, !atis.isEmpty {
                ForEach(atis) { info in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(info.callsign) · \(info.frequency)" + (info.code.map { " · Information \($0)" } ?? ""))
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(theme.text)
                        Text(info.text.isEmpty ? "No text" : info.text).font(.system(size: 13)).foregroundColor(theme.textSecondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                }
            } else {
                Text(atisError ?? (loading ? "Loading…" : "No ATIS online")).font(.system(size: 13)).foregroundColor(theme.textSecondary)
            }
        }
    }

    private var minimaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Minima").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.5)
            HStack(spacing: 10) {
                LabeledField(title: "Approach", text: $minima.approach, placeholder: "ILS 22")
                LabeledField(title: "DA / MDA", text: $minima.decision, placeholder: "200 ft", keyboard: .numbersAndPunctuation)
                LabeledField(title: "Vis / RVR", text: $minima.visibility, placeholder: "550 m", keyboard: .numbersAndPunctuation)
            }
        }
    }
}

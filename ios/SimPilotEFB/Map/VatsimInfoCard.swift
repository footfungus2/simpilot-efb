import SwiftUI

/// Compact popup for a tapped VATSIM pilot, airport or controller, in the app's mPilot chrome.
/// It sizes to its content: the frequency is the hero, the controller info text sits in a quiet inset,
/// and secondary facts (time online, booking) are small meta items at the bottom.
struct VatsimInfoCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: VatsimStore
    let selection: VatsimSelection
    @State private var expanded: Set<String> = []

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.separator).frame(height: 1)
            content
                .padding(16)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { store.selection = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.pill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var badge: some View {
        switch selection {
        case .pilot:
            iconBadge("airplane", Color(hex: 0x3D6BFF))
        case let .airport(icao):
            let letters = String(store.airportStations(icao).compactMap { Self.letter($0) })
            if letters.isEmpty { iconBadge("mappin", theme.textSecondary) } else { LetterBadges(letters: letters, size: 22) }
        case let .controller(cs):
            let c = store.controller(cs)
            letterBadge(c.map(Self.shortFacility) ?? "?", c.map(Self.color) ?? .gray)
        }
    }

    private func iconBadge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(color))
    }

    private func letterBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .foregroundColor(color == Self.atisYellow ? Color(hex: 0x1A1A1A) : .white)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(color))
    }

    private var title: String {
        let ref = VatsimReference.shared
        switch selection {
        case let .pilot(cs):
            return cs
        case let .airport(icao):
            return ref.airports[icao]?.name ?? icao
        case let .controller(cs):
            guard let c = store.controller(cs) else { return cs }
            if c.facility == 5, let t = ref.tracons(for: c.prefix).first.flatMap({ ref.traconFeatures[$0] }), !t.name.isEmpty {
                return t.name
            }
            if let id = ref.sectors(for: c.prefix).first, let name = ref.firNames[id] { return "\(name) \(c.facilityName)" }
            return ref.airport(for: c.prefix).map { "\($0.name) \(c.facilityName)" } ?? cs
        }
    }

    private var subtitle: String {
        switch selection {
        case let .pilot(cs):
            guard let p = store.pilot(cs) else { return "Offline" }
            return [p.flight_plan?.aircraft_short, p.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case let .airport(icao):
            let n = store.airportStations(icao).count
            return n == 0 ? "\(icao) · no ATC online" : "\(icao) · \(n) station\(n == 1 ? "" : "s") online"
        case let .controller(cs):
            return cs
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch selection {
        case let .pilot(cs):
            if let p = store.pilot(cs) { PilotDetails(pilot: p) } else { offline }
        case let .airport(icao):
            AirportDetails(store: store, icao: icao, expanded: $expanded)
        case let .controller(cs):
            if let c = store.controller(cs) {
                ControllerDetails(controller: c, bookedUntil: store.bookedUntil(c.callsign))
            } else {
                offline
            }
        }
    }

    private var offline: some View {
        Text("No longer online.").font(.system(size: 14)).foregroundColor(theme.textSecondary)
    }

    // MARK: Facility helpers

    static let atisYellow = Color(hex: 0xF2B705)

    static func letter(_ c: VatsimController) -> Character? {
        if c.isAtis { return "A" }
        return [2: "D", 3: "G", 4: "T"][c.facility]
    }

    static func shortFacility(_ c: VatsimController) -> String {
        c.isAtis ? "ATIS" : [1: "FSS", 2: "DEL", 3: "GND", 4: "TWR", 5: "APP", 6: "CTR"][c.facility] ?? "ATC"
    }

    static func color(_ c: VatsimController) -> Color {
        if c.isAtis { return atisYellow }
        switch c.facility {
        case 2: return Color(hex: 0x3B6CF0)
        case 3: return Color(hex: 0x3E9A3A)
        case 4: return Color(hex: 0xD9301E)
        case 5: return Color(hex: 0xE5533F)
        default: return Color(hex: 0x4A8A34)
        }
    }
}

// MARK: - Controller

private struct ControllerDetails: View {
    @Environment(\.theme) private var theme
    let controller: VatsimController
    let bookedUntil: String?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(controller.frequency)
                    .font(.system(size: compact ? 20 : 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(theme.text)
                Text("MHz").font(.system(size: 12, weight: .medium)).foregroundColor(theme.textSecondary)
                Spacer()
                if let url = URL(string: "https://listen.vatsim.net/live/\(controller.callsign)") {
                    Link(destination: url) {
                        Label("Listen", systemImage: "speaker.wave.2.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.selectedBlue)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Capsule().fill(Theme.selectedBlue.opacity(0.15)))
                    }
                }
            }

            if !controller.isAtis {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill").font(.system(size: 12)).foregroundColor(theme.textSecondary)
                    Text(controller.name).font(.system(size: 14)).foregroundColor(theme.text).lineLimit(1)
                    Text(controller.ratingName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.selectedBlue))
                }
            }

            if let lines = controller.text_atis?.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }), !lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(Linkify.attributed(line))
                            .font(.system(size: 13))
                            .foregroundColor(theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
            }

            HStack(spacing: 16) {
                meta("clock", "Online \(controller.onlineFor)")
                if let bookedUntil { meta("calendar", "Booked until \(bookedUntil)") }
            }
        }
    }

    private func meta(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 12)).monospacedDigit()
        }
        .foregroundColor(theme.textSecondary)
    }
}

// MARK: - Airport

private struct AirportDetails: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: VatsimStore
    let icao: String
    @Binding var expanded: Set<String>

    var body: some View {
        let stations = store.airportStations(icao)
        let traffic = store.traffic(icao)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                count("arrowtriangle.up.fill", Color(hex: 0x3E9A3A), traffic.departing, "Departing")
                count("minus", theme.text, traffic.landed, "On ground")
                count("arrowtriangle.down.fill", Color(hex: 0xE2401E), traffic.arriving, "Arriving")
            }
            ForEach(stations, id: \.callsign) { c in
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        if expanded.contains(c.callsign) { expanded.remove(c.callsign) } else { expanded.insert(c.callsign) }
                    } label: {
                        HStack(spacing: 10) {
                            LetterBadges(letters: String(VatsimInfoCard.letter(c) ?? "?"), size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.callsign).font(.system(size: 14, weight: .semibold)).foregroundColor(theme.text)
                                Text(c.isAtis ? "ATIS" : c.name).font(.system(size: 12)).foregroundColor(theme.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Text(c.frequency).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundColor(theme.text)
                            Image(systemName: expanded.contains(c.callsign) ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(c.callsign) {
                        ControllerDetails(controller: c, bookedUntil: store.bookedUntil(c.callsign), compact: true)
                            .padding(.leading, 32)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.pill.opacity(0.6)))
            }
        }
    }

    private func count(_ symbol: String, _ color: Color, _ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundColor(color)
                Text("\(n)").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(theme.text)
            }
            Text(label).font(.system(size: 11)).foregroundColor(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
    }
}

// MARK: - Pilot

private struct PilotDetails: View {
    @Environment(\.theme) private var theme
    let pilot: VatsimPilot
    @State private var showRoute = false

    var body: some View {
        let fp = pilot.flight_plan
        VStack(alignment: .leading, spacing: 12) {
            if let dep = fp?.departure, let arr = fp?.arrival, !dep.isEmpty {
                HStack(spacing: 12) {
                    Text(dep).font(.system(size: 24, weight: .semibold, design: .rounded))
                    Rectangle().fill(theme.separator).frame(height: 1)
                        .overlay(Image(systemName: "airplane").font(.system(size: 13)).foregroundColor(theme.textSecondary)
                                    .padding(.horizontal, 6).background(theme.sidebar))
                    Text(arr).font(.system(size: 24, weight: .semibold, design: .rounded))
                }
                .foregroundColor(theme.text)
            }
            HStack(spacing: 8) {
                stat("ALT", "\(Int(pilot.altitude))")
                stat("GS", "\(Int(pilot.groundspeed))")
                stat("HDG", String(format: "%03d", Int(pilot.heading)))
                stat("SQK", pilot.transponder ?? "–")
            }
            if let route = fp?.route, !route.isEmpty {
                Button { showRoute.toggle() } label: {
                    Text(route)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(showRoute ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
    }
}

// MARK: - Shared bits

/// D/G/T/A squares joined into one rounded strip, as on the map.
struct LetterBadges: View {
    let letters: String
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: size * 0.6, weight: .heavy))
                    .foregroundColor(ch == "A" ? Color(hex: 0x1A1A1A) : .white)
                    .frame(width: size, height: size)
                    .background(color(ch))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func color(_ ch: Character) -> Color {
        switch ch {
        case "D": return Color(hex: 0x3B6CF0)
        case "G": return Color(hex: 0x3E9A3A)
        case "T": return Color(hex: 0xD9301E)
        case "A": return VatsimInfoCard.atisYellow
        default: return .gray
        }
    }
}

/// Turns bare links in controller info ("vats.im/atcfb", "chartfox.org/EGKK") into tappable links.
enum Linkify {
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s|,;)]*)?"#, options: [.caseInsensitive])

    static func attributed(_ line: String) -> AttributedString {
        var out = AttributedString(line)
        guard let pattern else { return out }
        for m in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let r = Range(m.range, in: line) else { continue }
            var raw = String(line[r])
            while let last = raw.last, ".:".contains(last) { raw.removeLast() } // trailing punctuation
            // Skip things like "S2" or version numbers: require a letter-only TLD of 2+ chars.
            let urlString = raw.lowercased().hasPrefix("http") ? raw : "https://\(raw)"
            guard let url = URL(string: urlString),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(line.index(r.lowerBound, offsetBy: raw.count), within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].foregroundColor = Color(hex: 0x4A86FF)
        }
        return out
    }
}

/// VATSIM layer settings: on/off, search, and what to draw.
struct VatsimFilterPanel: View {
    @ObservedObject var store: VatsimStore
    @State private var query = ""
    @State private var notFound = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $store.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VATSIM").font(.headline)
                        Text(status).font(.caption).foregroundColor(.secondary)
                    }
                }

                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Find callsign or airport", text: $query)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .onSubmit { notFound = !store.search(query) }
                    if !query.isEmpty {
                        Button { query = ""; store.search("") } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                .disabled(!store.enabled)
                if notFound { Text("Not online.").font(.caption).foregroundColor(.orange) }

                section("Pilots") {
                    Toggle("Show pilots", isOn: $store.filters.pilots)
                    Toggle("Ground traffic", isOn: $store.filters.groundTraffic)
                    Toggle("Callsign labels", isOn: $store.filters.pilotLabels)
                    Toggle("Only to/from my flight's airports", isOn: $store.filters.onlyMyAirports)
                    Picker("Altitude", selection: $store.filters.minAltitude) {
                        ForEach(VatsimFilters.MinAltitude.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                section("ATC") {
                    Toggle("Centre sectors (CTR/FSS)", isOn: $store.filters.sectors)
                    Text("Sectors show who actually controls the airspace at FL\(store.displayLevel) — change the level in the FL box on the map.")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("Approach (APP)", isOn: $store.filters.approach)
                    Toggle("Tower, ground, delivery", isOn: $store.filters.localAtc)
                    Toggle("ATIS", isOn: $store.filters.atis)
                }
                section("Airports") {
                    Toggle("Traffic counts", isOn: $store.filters.trafficCounts)
                    Toggle("Airports without ATC", isOn: $store.filters.idleAirports)
                    HStack(spacing: 14) {
                        legend("arrowtriangle.up.fill", Color(hex: 0x3E9A3A), "departing")
                        legend("minus.rectangle.fill", .primary, "on ground")
                        legend("arrowtriangle.down.fill", Color(hex: 0xE2401E), "arriving")
                    }
                    .font(.caption)
                }
                .disabled(!store.enabled)
            }
            .padding()
        }
        .frame(width: 340, height: 560)
    }

    private var status: String {
        guard store.enabled else { return "Off" }
        if let err = store.error { return err }
        guard let f = store.feed else { return "Loading…" }
        return "\(f.pilots.count) pilots · \(f.controllers.count) ATC online"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            content()
        }
        .disabled(!store.enabled)
    }

    private func legend(_ symbol: String, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundColor(color)
            Text(label).foregroundColor(.secondary)
        }
    }
}

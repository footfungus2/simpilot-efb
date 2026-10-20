import SwiftUI

/// Enter the taxi route ATC gives you ("J C B") and it lights up on the airport map.
/// Tap taxiway names in order, or type them; Clear removes the route.
struct TaxiRoutePanel: View {
    @EnvironmentObject private var app: AppState
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Taxi route").font(.headline)
                Spacer()
                Menu {
                    ForEach(airportChoices, id: \.self) { icao in
                        Button(icao) { app.taxiRouteAirport = icao; app.taxiRoute = [] }
                    }
                } label: {
                    Label(airport ?? "Airport", systemImage: "chevron.down").font(.subheadline.weight(.semibold))
                }
            }

            TextField("e.g. J C B", text: $typed)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .onSubmit(applyTyped)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))

            if !app.taxiRoute.isEmpty {
                Text(app.taxiRoute.joined(separator: " → "))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(hex: 0xFF4FD8))
            }

            if let names = airport.flatMap({ app.taxiwayNames[$0] }), !names.isEmpty {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            let used = app.taxiRoute.contains(name)
                            Button { toggle(name) } label: {
                                Text(name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(used ? .white : .primary)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(used ? Color(hex: 0xC2399F) : Color.secondary.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else {
                Text("Zoom into the airport on the map first so its taxiways load.")
                    .font(.footnote).foregroundColor(.secondary)
            }

            HStack {
                Button("Clear", role: .destructive) { app.taxiRoute = []; typed = "" }
                    .disabled(app.taxiRoute.isEmpty)
                Spacer()
                Button("Undo last") { _ = app.taxiRoute.popLast() }
                    .disabled(app.taxiRoute.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            if app.taxiRouteAirport == nil { app.taxiRouteAirport = defaultAirport }
        }
    }

    private var airport: String? { app.taxiRouteAirport ?? defaultAirport }

    /// Where you are on the ground, else the departure airport.
    private var defaultAirport: String? {
        if let o = app.bridge.ownship.ownship, let near = AirportIndex.nearest(to: o.coordinate, withinKm: 8) { return near }
        return app.ofp?.origin.icao ?? app.taxiwayNames.keys.sorted().first
    }

    private var airportChoices: [String] {
        Array(Set(app.taxiwayNames.keys).union(app.flightAirports.map(\.icao))).sorted()
    }

    private func toggle(_ name: String) {
        if app.taxiRouteAirport == nil { app.taxiRouteAirport = airport }
        if let i = app.taxiRoute.firstIndex(of: name) { app.taxiRoute.remove(at: i) } else { app.taxiRoute.append(name) }
    }

    private func applyTyped() {
        if app.taxiRouteAirport == nil { app.taxiRouteAirport = airport }
        let known = Set(airport.flatMap { app.taxiwayNames[$0] } ?? [])
        // Accept "J C B", "J,C,B" or "J-C-B"; keep names the airport actually has (case-insensitive).
        let parts = typed.uppercased().split(whereSeparator: { " ,-→>".contains($0) }).map(String.init)
        app.taxiRoute = parts.compactMap { p in known.first { $0.uppercased() == p } ?? (known.isEmpty ? p : nil) }
    }
}

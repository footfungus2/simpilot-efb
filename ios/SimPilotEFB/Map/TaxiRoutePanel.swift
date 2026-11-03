import SwiftUI

/// Enter the taxi route ATC gives you ("J C B") and it lights up on the airport map.
/// Tap taxiway names in order, or type them; Clear removes the route.
struct TaxiRoutePanel: View {
    @EnvironmentObject private var app: AppState
    @State private var typed = ""
    @State private var standText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Taxi route").font(.headline)
                Spacer()
                Menu {
                    ForEach(airportChoices, id: \.self) { icao in
                        Button(icao) { app.taxiRouteAirport = icao; app.taxiRoute = []; app.selectedStand = nil; app.selectedHold = nil; standText = "" }
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

            Divider()
            standSection
            holdSection
            Divider()

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

    private var ground: AirportGround? { airport.flatMap { app.ground[$0] } }

    // MARK: Stand

    /// Pick the stand ATC gave you: its lead-in line lights up green on the airport map and the distance shows while taxiing.
    @ViewBuilder private var standSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Stand").font(.subheadline.weight(.semibold))
                Spacer()
                if app.selectedStand != nil {
                    Button("Clear") { app.selectedStand = nil; standText = "" }.font(.subheadline)
                }
            }
            if let ground, !ground.stands.isEmpty {
                TextField("Stand, e.g. 225", text: $standText)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .onChange(of: standText) { text in
                        if let exact = ground.stand(text.trimmingCharacters(in: .whitespaces)) { app.selectedStand = exact.ref }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                let suggestions = standSuggestions(ground)
                if !suggestions.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], spacing: 6) {
                        ForEach(suggestions) { stand in
                            Button { app.selectedStand = stand.ref; standText = stand.ref } label: {
                                Text(stand.ref).font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(app.selectedStand == stand.ref ? .white : .primary)
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(app.selectedStand == stand.ref ? Theme.okGreen : Color.secondary.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let ref = app.selectedStand {
                    Text(ground.stand(ref) == nil ? "Stand \(ref) isn't on this airport's map." : "Stand \(ref): green line on the map.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            } else {
                Text("Zoom into the airport on the map first so its stands load.").font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    /// Stands that start with what was typed (all of them when nothing is typed, first twelve).
    private func standSuggestions(_ ground: AirportGround) -> [AirportGround.Stand] {
        let typed = standText.trimmingCharacters(in: .whitespaces).uppercased()
        return Array(ground.stands.filter { typed.isEmpty || $0.ref.uppercased().hasPrefix(typed) }.prefix(12))
    }

    // MARK: Holding point

    /// The holding point you were told to stop at: marked red on the map, with the distance while taxiing.
    @ViewBuilder private var holdSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hold short at").font(.subheadline.weight(.semibold))
                Spacer()
                if app.selectedHold != nil {
                    Button("Clear") { app.selectedHold = nil }.font(.subheadline)
                }
            }
            if let ground, !ground.holds.isEmpty {
                Menu {
                    ForEach(sortedHolds(ground)) { hold in
                        Button(holdTitle(hold)) { app.selectedHold = hold.id }
                    }
                } label: {
                    Label(app.selectedHold.flatMap { ground.hold($0)?.label } ?? "Choose a holding point", systemImage: "chevron.down")
                        .font(.subheadline)
                }
            } else {
                Text("Zoom into the airport on the map first so its holding points load.").font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    /// Nearest first when the aircraft's position is known, else by name.
    private func sortedHolds(_ ground: AirportGround) -> [AirportGround.Hold] {
        if let o = app.bridge.ownship.ownship {
            return ground.holds.sorted { AirportGround.meters($0.coordinate, o.coordinate) < AirportGround.meters($1.coordinate, o.coordinate) }
        }
        return ground.holds.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func holdTitle(_ hold: AirportGround.Hold) -> String {
        guard let o = app.bridge.ownship.ownship else { return hold.label }
        let meters = AirportGround.meters(hold.coordinate, o.coordinate)
        return "\(hold.label) · \(meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000))"
    }

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

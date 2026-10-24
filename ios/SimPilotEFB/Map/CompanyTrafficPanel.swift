import SwiftUI

struct CompanyTrafficPanel: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var store: VatsimStore
    let ownship: Ownship?

    private var pilots: [VatsimPilot] {
        store.companyPilots.sorted { a, b in
            guard let ownship else { return a.callsign < b.callsign }
            return MapRuler.distanceNM(ownship.coordinate, a.coordinate) < MapRuler.distanceNM(ownship.coordinate, b.coordinate)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Company traffic (VATSIM)", isOn: $app.companyTraffic).font(.headline)
                TextField(app.companyCode ?? "Airline code, e.g. EZY", text: $app.companyCodeOverride)
                    .textInputAutocapitalization(.characters).disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: app.companyCodeOverride) { value in
                        let code = String(value.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(3))
                        if code != value { app.companyCodeOverride = code }
                    }
                    .accessibilityLabel("Three-letter airline code")
                Text("Leave blank to use the airline from your SimBrief callsign. Company flights are orange, even with the VATSIM layer off.")
                    .font(.caption).foregroundColor(theme.textSecondary)
                if !app.companyTraffic {
                    Text("Company traffic is off.")
                } else if app.companyCode == nil {
                    Text("Load a SimBrief flight with an airline callsign or enter a three-letter code.")
                } else if let error = store.error {
                    Text(error).foregroundColor(.orange)
                    Button("Retry") { Task { await store.refresh() } }
                } else if store.feed == nil {
                    SkeletonBlock(height: 50)
                } else if pilots.isEmpty {
                    Text("No \(app.companyCode ?? "company") flights online.")
                }
                if app.companyTraffic {
                    ForEach(Array(pilots.enumerated()), id: \.element.callsign) { index, pilot in
                        Button {
                            app.rulerActive = false
                            app.mapPick = nil
                            app.weather.selectedSigmet = nil
                            store.search(pilot.callsign)
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(pilot.callsign).font(.headline)
                                    Spacer()
                                    Text(pilot.flight_plan?.aircraft_short ?? "–")
                                }
                                Text("\(pilot.flight_plan?.departure ?? "–") → \(pilot.flight_plan?.arrival ?? "–")")
                                Text(String(format: "FL%03.0f · %.0f kt", pilot.altitude / 100, pilot.groundspeed))
                                    .font(.caption).foregroundColor(theme.textSecondary)
                            }
                            .foregroundColor(theme.text).padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                        }
                        .buttonStyle(.pressableSoft)
                        .staggeredEntrance(index)
                    }
                }
            }.padding()
                .animation(Motion.smooth, value: store.version)
        }.frame(width: 350, height: 440)
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.presentationMode) private var presentationMode
    @State private var hostDraft = ""
    @State private var simbriefDraft = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Bridge"), footer: Text("Leave empty to find the bridge automatically. Otherwise enter the PC's address shown in the bridge window, e.g. 192.168.1.20:8380.")) {
                    TextField("Auto-discover", text: $hostDraft)
                        .keyboardType(.numbersAndPunctuation)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .onSubmit(applyHost)
                    Button("Reconnect", action: applyHost)
                    LabeledRow("Bridge", bridgeState)
                    LabeledRow("Simulator", bridge.status.map { $0.sim.connected ? "Connected" : "Not running" } ?? "–")
                    if let title = bridge.status?.sim.aircraftTitle {
                        LabeledRow("Aircraft", title)
                    }
                    LabeledRow("SimPilot Link panel", bridge.status.map { $0.link.connected ? "Connected" : "Not open in the sim" } ?? "–")
                }

                Section(header: Text("SimBrief"), footer: Text("Your SimBrief username or pilot ID. The latest OFP is loaded into the Flight Folder.")) {
                    TextField("Username or pilot ID", text: $simbriefDraft)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .onSubmit { app.simbriefUser = simbriefDraft }
                    Button {
                        app.simbriefUser = simbriefDraft
                        Task { await app.loadOfp() }
                    } label: {
                        HStack {
                            Text("Load latest OFP")
                            if app.ofpLoading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(simbriefDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let err = app.ofpError { Text(err).foregroundColor(Theme.warnOrange) }
                    if let ofp = app.ofp {
                        LabeledRow("Loaded", "\(ofp.callsign) \(ofp.origin.icao)–\(ofp.destination.icao)")
                    }
                }

                Section(header: Text("Demo flight (no simulator)"),
                        footer: Text("Flies a simulated aircraft along your SimBrief route so you can test the map, vertical profile and charts without MSFS or the bridge.")) {
                    Toggle("Fly the loaded route", isOn: $app.demoEnabled)
                        .disabled(app.ofp == nil)
                    Picker("Speed", selection: $app.demoSpeed) {
                        Text("1×").tag(1.0)
                        Text("8×").tag(8.0)
                        Text("32×").tag(32.0)
                        Text("128×").tag(128.0)
                    }
                    .pickerStyle(.segmented)
                    Button("Restart from departure") { app.restartDemo() }
                        .disabled(!app.demoEnabled)
                }

                Section(header: Text("Display")) {
                    Toggle("Night mode", isOn: $app.night)
                }

                Section(header: Text("About"), footer: Text("SimPilot EFB is an unofficial flight-sim tool for personal use. Chart data comes from your own MSFS 2024 installation. FIR boundaries: VATSpy Data Project (CC BY-SA 4.0). Basemap: Natural Earth. Airports: OurAirports. Airport maps © OpenStreetMap contributors (ODbL). VATSIM data: data.vatsim.net, TRACONs: SimAware TRACON Project (CC BY-SA 4.0). Sector ownership: VATGlasses Data Project (CC BY-NC-SA 4.0).")) {
                    LabeledRow("Version", Bundle.main.shortVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        app.simbriefUser = simbriefDraft
                        if hostDraft != app.bridgeHost { applyHost() }
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            hostDraft = app.bridgeHost
            simbriefDraft = app.simbriefUser
        }
    }

    private var bridgeState: String {
        switch bridge.state {
        case .idle: return "Idle"
        case .searching: return "Searching…"
        case let .connecting(h): return "Connecting to \(h)…"
        case let .connected(h): return "Connected (\(h))"
        }
    }

    private func applyHost() {
        app.bridgeHost = hostDraft.trimmingCharacters(in: .whitespaces)
        app.connect()
    }
}

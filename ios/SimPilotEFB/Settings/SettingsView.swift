import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @EnvironmentObject private var updates: UpdateChecker
    @Environment(\.openURL) private var openURL
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.theme) private var theme
    @State private var hostDraft = ""
    @State private var simbriefDraft = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    NavigationLink {
                        CustomizationView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accentColor))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Customization")
                                Text("Theme, accent colour, animations, map and start screen")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section(header: Text("Bridge"), footer: Text("Leave empty to find the bridge automatically. Otherwise enter the PC's address shown in the bridge window, e.g. 192.168.1.20:8386.")) {
                    TextField("Auto-discover", text: $hostDraft)
                        .keyboardType(.numbersAndPunctuation)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .onSubmit(applyHost)
                    Button("Reconnect", action: applyHost)
                    LabeledRow("Bridge", bridgeState)
                    if let error = bridge.lastError { Text(error).foregroundColor(Theme.warnOrange) }
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

                Section(header: Text("Help")) {
                    NavigationLink("Diagnostics / debug console") {
                        DiagnosticsView()
                    }
                }

                Section(header: Text("Updates"), footer: Text("Updates are optional. Update opens your installer. If detection is unavailable, choose the installer you used for this app.")) {
                    LabeledRow("Installed", updates.installed)
                    LabeledRow("Detected installer", updates.detectedInstaller?.rawValue ?? "Unknown")
                    Picker("Update with", selection: $updates.installerChoice) {
                        Text("Automatic").tag("Automatic")
                        ForEach(UpdateInstaller.allCases, id: \.rawValue) { installer in
                            Text(installer.rawValue).tag(installer.rawValue)
                        }
                    }
                    if let release = updates.available {
                        if updates.installer == nil {
                            Text("Choose SideStore or TrollStore above to update.").font(.footnote)
                        }
                        Button("Update to \(release.version) (\(release.build))") {
                            guard let url = updates.installURL else { return }
                            DiagnosticLog.record(.info, "Updates", "Opening the selected installer at the user's request")
                            openURL(url) { accepted in
                                if !accepted {
                                    DiagnosticLog.record(.warning, "Updates", "Installer couldn't open; showing the manual download page")
                                    openURL(AppRelease.page)
                                }
                            }
                        }
                        .disabled(updates.installer == nil)
                    }
                    Button {
                        Task { await updates.check() }
                    } label: {
                        HStack {
                            Text("Check for updates")
                            if updates.checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(updates.checking)
                    if let message = updates.message { Text(message).font(.footnote) }
                    Link("Release notes / manual download", destination: AppRelease.page)
                }

                Section(header: Text("About"), footer: Text("SimPilot EFB is an unofficial flight-sim tool for personal use. Chart data comes from your own MSFS 2024 installation. FIR boundaries: VATSpy Data Project (CC BY-SA 4.0). Basemap: Natural Earth. Airports: OurAirports. Airport maps © OpenStreetMap contributors (ODbL). VATSIM data: data.vatsim.net, TRACONs: SimAware TRACON Project (CC BY-SA 4.0). Sector ownership: VATGlasses Data Project (CC BY-NC-SA 4.0).")) {
                    LabeledRow("Version", Bundle.main.shortVersion)
                }
            }
            // Status rows that come and go (errors, spinners, the update button) fade instead of popping.
            .animation(Motion.smooth, value: bridge.lastError)
            .animation(Motion.smooth, value: app.ofpError)
            .animation(Motion.smooth, value: app.ofpLoading)
            .animation(Motion.smooth, value: app.ofp?.fetchedAt)
            .animation(Motion.smooth, value: updates.checking)
            .animation(Motion.smooth, value: updates.message)
            .animation(Motion.smooth, value: updates.available?.version)
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

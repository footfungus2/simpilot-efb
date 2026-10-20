import SwiftUI

/// The mPilot top bar: menu + cycle title, centre tool pill, aircraft pill, search and sync status.
struct TopBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme
    @State private var showSearch = false
    @State private var showHelp = false
    @State private var wxOffsetHours = 0

    var body: some View {
        HStack(spacing: 12) {
            RoundIconButton(systemName: "line.3.horizontal") {
                withAnimation(.easeInOut(duration: 0.2)) { app.sidebarVisible.toggle() }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer(minLength: 8)

            PillGroup {
                Menu {
                    ForEach(0..<13) { h in
                        Button(String(format: "+%02d:00", h)) { wxOffsetHours = h }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 16))
                        Text(String(format: "+%02d:00", wxOffsetHours)).font(.system(size: 15)).monospacedDigit()
                    }
                    .foregroundColor(theme.text)
                    .padding(.horizontal, 6)
                }
                PillIcon(systemName: "questionmark.circle") { showHelp = true }
                PillIcon(systemName: app.night ? "moon.zzz" : "sun.max") { app.night.toggle() }
                PillIcon(systemName: "character.bubble") {}
                Text("v \(Bundle.main.shortVersion)")
                    .font(.system(size: 9))
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 6)
            }

            Spacer(minLength: 8)

            PillGroup {
                Text(aircraftLabel)
                    .font(.system(size: 15))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                    .padding(.leading, 8)
                PillIcon(systemName: "airplane") { app.showSettings = true }
            }
            .frame(maxWidth: 260)

            RoundIconButton(systemName: "magnifyingglass") { showSearch = true }
            SyncStatusButton()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(theme.bar)
        .sheet(isPresented: $showSearch) { AirportSearchSheet().environmentObject(app).environment(\.theme, theme) }
        .sheet(isPresented: $showHelp) { HelpSheet().environment(\.theme, theme) }
    }

    private var title: String {
        if app.module == .charts, let icao = app.chartsAirport { return "\(icao): \(app.cycleTitle.replacingOccurrences(of: "Cycle: ", with: ""))" }
        return app.cycleTitle
    }

    private var subtitle: String {
        app.ofp == nil ? "Route not saved" : app.routeSubtitle
    }

    private var aircraftLabel: String {
        if let title = bridge.status?.sim.aircraftTitle, !title.isEmpty { return title.uppercased() }
        if let name = app.ofp?.aircraft.name, !name.isEmpty { return name.uppercased() }
        return "NO AIRCRAFT"
    }
}

/// Green ✓ when the sim and in-sim link are both connected; orange when only partly; grey when offline.
struct SyncStatusButton: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var bridge: BridgeClient
    @Environment(\.theme) private var theme

    var body: some View {
        Button { app.showSettings = true } label: {
            ZStack {
                Circle().fill(theme.pill).frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(color)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private var level: Int {
        guard bridge.isConnected, let s = bridge.status else { return 0 }
        return s.sim.connected && s.link.connected ? 2 : 1
    }

    private var symbol: String { level == 0 ? "wifi.exclamationmark" : level == 1 ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    private var color: Color { level == 0 ? theme.textSecondary : level == 1 ? Theme.warnOrange : Theme.okGreen }
    private var accessibility: String {
        switch level {
        case 0: return "Bridge not connected"
        case 1: return "Bridge connected, sim or link missing"
        default: return "All connected"
        }
    }
}

struct AirportSearchSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.theme) private var theme
    @State private var query = ""

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("Opens the Lido charts for an airport. The SimPilot Link panel must be open in the sim the first time an airport is loaded.")) {
                    TextField("ICAO code, e.g. EDDF", text: $query)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .onSubmit(open)
                }
                if !app.flightAirports.isEmpty {
                    Section(header: Text("This flight")) {
                        ForEach(app.flightAirports, id: \.icao) { apt in
                            Button { query = apt.icao; open() } label: {
                                HStack {
                                    Text(apt.icao).font(.system(size: 17, weight: .semibold))
                                    Text(apt.name).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open", action: open).disabled(icao == nil) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var icao: String? {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        return q.range(of: "^[A-Z0-9]{4}$", options: .regularExpression) != nil ? q : nil
    }

    private func open() {
        guard let icao else { return }
        app.openCharts(icao)
        presentationMode.wrappedValue.dismiss()
    }
}

struct HelpSheet: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Getting connected")) {
                    Text("1. Start the SimPilot bridge on the flight-sim PC (start-bridge.bat).")
                    Text("2. In MSFS 2024, open the SimPilot Link panel from the toolbar once per session.")
                    Text("3. The iPad finds the bridge automatically. If it doesn't, enter the PC's address in Settings.")
                }
                Section(header: Text("Status icon")) {
                    Label("Bridge, sim and link connected", systemImage: "checkmark.circle.fill").foregroundColor(Theme.okGreen)
                    Label("Bridge connected, sim or link missing", systemImage: "exclamationmark.circle.fill").foregroundColor(Theme.warnOrange)
                    Label("Bridge not found", systemImage: "wifi.exclamationmark")
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}

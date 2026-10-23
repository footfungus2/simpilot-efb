import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var bridge: BridgeClient
    @EnvironmentObject private var updates: UpdateChecker
    @ObservedObject private var log = DiagnosticLog.shared
    @State private var loadingBridge = false
    @State private var copied = false

    private var bridgeState: String {
        switch bridge.state {
        case .idle: return "Not connected"
        case .searching: return "Searching on local network"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    private var summary: [String] {
        ["SimPilot EFB \(updates.installed)", "iPadOS \(UIDevice.current.systemVersion)",
         "Update installer: \(updates.installer?.rawValue ?? "Unknown")", "Bridge: \(bridgeState)",
         "Simulator: \(bridge.status?.sim.connected == true ? "Connected" : "Not connected")",
         "Chart link: \(bridge.status?.link.connected == true ? "Connected" : "Not connected")"]
    }

    var body: some View {
        Form {
            Section(header: Text("Current status")) {
                LabeledRow("App", updates.installed)
                LabeledRow("Bridge", bridgeState)
                LabeledRow("Simulator", bridge.status?.sim.connected == true ? "Connected" : "Not connected")
                LabeledRow("Chart link", bridge.status?.link.connected == true ? "Connected" : "Not connected")
                AircraftDataRow(ownship: bridge.ownship)
                LabeledRow("Update installer", updates.installer?.rawValue ?? "Unknown")
                if let error = bridge.lastError { Text(error).foregroundColor(Theme.warnOrange) }
            }
            Section(header: Text("Report"), footer: Text("Logs stay on this device for this session. Copy a report when asking for help. Account details and flight plans aren't recorded; review the report before sharing.")) {
                Button(copied ? "Report copied" : "Copy diagnostic report") {
                    UIPasteboard.general.string = log.buffer.report(summary: summary)
                    copied = true
                }
                Button {
                    Task { await loadBridgeLogs() }
                } label: {
                    HStack {
                        Text("Load PC bridge logs")
                        if loadingBridge { Spacer(); ProgressView() }
                    }
                }
                .disabled(!bridge.isConnected || loadingBridge)
                Button("Clear console") { log.clear(); copied = false }
            }
            Section(header: Text("Console · \(log.buffer.entries.count) / 300")) {
                if log.buffer.entries.isEmpty {
                    Text("No events recorded. Reproduce the issue, then return here.").foregroundColor(.secondary)
                }
                ForEach(log.buffer.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.time, style: .time)
                            Text(entry.level.rawValue.uppercased())
                            Text(entry.scope)
                        }
                        .font(.caption)
                        .foregroundColor(entry.level == .error ? Theme.warnOrange : .secondary)
                        Text(entry.message).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct BridgeLogs: Decodable {
        struct Entry: Decodable {
            let time: String
            let level: String
            let scope: String
            let message: String
        }
        let entries: [Entry]
    }

    @MainActor private func loadBridgeLogs() async {
        loadingBridge = true
        defer { loadingBridge = false }
        do {
            guard let response: BridgeLogs = try await bridge.get("/api/diagnostics") else { return }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for entry in response.entries.suffix(200) {
                let level = entry.level == "warn" ? DiagnosticLevel.warning : DiagnosticLevel(rawValue: entry.level) ?? .info
                log.append(level, "PC · \(entry.scope)", entry.message,
                           time: formatter.date(from: entry.time) ?? Date())
            }
            log.append(.info, "Diagnostics", "PC bridge logs loaded")
        } catch {
            DiagnosticLog.record(.warning, "Diagnostics", "Couldn't load PC logs. Check the connection and bridge version.", error: error)
        }
    }
}

private struct AircraftDataRow: View {
    @ObservedObject var ownship: OwnshipStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = ownship.ownship.map { max(0, context.date.timeIntervalSince1970 - $0.ts / 1000) }
            LabeledRow("Last aircraft data", age.map { "\(Int(min($0, 86_400))) seconds ago" } ?? "Not received")
        }
    }
}

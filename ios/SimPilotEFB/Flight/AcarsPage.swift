import SwiftUI

/// ACARS on Hoppie's network (VATSIM): pre-departure clearance, telexes, weather requests and CPDLC with ATC.
struct AcarsPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var hoppie: HoppieStore
    var compact: Bool

    @State private var station = ""
    @State private var text = ""
    @State private var infoIcao = ""
    @State private var stand = ""
    @State private var atis = ""

    var body: some View {
        VStack(spacing: 16) {
            connectionCard
            if hoppie.configured {
                AdaptiveStack(compact: compact) {
                    VStack(spacing: 16) {
                        sendCard
                        pdcCard
                    }
                    messagesCard
                }
            }
        }
        .onAppear {
            if hoppie.callsign.isEmpty, let ofp = app.ofp { hoppie.callsign = ofp.callsign }
            if infoIcao.isEmpty { infoIcao = app.ofp?.destination.icao ?? "" }
            if stand.isEmpty { stand = app.selectedStand ?? "" }
            hoppie.markRead()
        }
        .onChange(of: hoppie.unreadCount) { _ in hoppie.markRead() }
    }

    // MARK: Connection

    private var connectionCard: some View {
        Card(title: "Hoppie ACARS", accessory: {
            Text(statusText).font(.system(size: 13, weight: .medium)).foregroundColor(statusColor)
        }, content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LOGON CODE").font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.5)
                        SecureField("from hoppie.nl", text: $hoppie.logon)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                            .font(.system(size: 16, weight: .medium)).foregroundColor(theme.text)
                            .padding(.horizontal, 10).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                    }
                    LabeledField(title: "Callsign", text: $hoppie.callsign, placeholder: "EZY128W")
                }
                if !hoppie.configured {
                    Text("Get a free logon code at hoppie.nl/acars (Get Logon Code), paste it here once, and enter the callsign you fly with. The code stays in this iPad's Keychain.")
                        .font(.system(size: 13)).foregroundColor(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        ActionButton(label: hoppie.polling ? "Go offline" : "Go online", systemImage: hoppie.polling ? "wifi.slash" : "antenna.radiowaves.left.and.right",
                                     prominent: !hoppie.polling, minWidth: 0) {
                            if hoppie.polling { hoppie.goOffline() } else { hoppie.goOnline() }
                        }
                        ActionButton(label: "Check messages", systemImage: "arrow.clockwise", pending: hoppie.state == .working, minWidth: 0) {
                            Task { await hoppie.poll() }
                        }
                    }
                    Text("Messages are collected about once a minute once you are online (or after your first message). The network is shared: send only what you need.")
                        .font(.system(size: 12)).foregroundColor(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        })
    }

    private var statusText: String {
        switch hoppie.state {
        case .idle: return hoppie.polling ? "Online" : "Offline"
        case .working: return "Working…"
        case let .online(at): return "Online · \(FlightFormat.time(at))"
        case let .failed(message): return message
        }
    }

    private var statusColor: Color {
        switch hoppie.state {
        case .online: return Theme.okGreen
        case .failed: return Theme.warnOrange
        default: return theme.textSecondary
        }
    }

    // MARK: Sending

    private var sendCard: some View {
        Card(title: "Send") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: "To (ATC callsign or station)", text: $station, placeholder: "EGSS_TWR")
                LabeledField(title: "Message", text: $text, placeholder: "REQUEST …", capitalized: true)
                HStack(spacing: 10) {
                    ActionButton(label: "Send telex", systemImage: "paperplane", prominent: true, minWidth: 0) {
                        let to = station, message = text
                        text = ""
                        Task { await hoppie.sendTelex(to: to, message) }
                    }
                    .disabled(station.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    ActionButton(label: "Request CPDLC logon", minWidth: 0) {
                        let to = station
                        Task { await hoppie.requestLogon(to: to) }
                    }
                    .disabled(station.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Divider()
                HStack(spacing: 10) {
                    LabeledField(title: "Airport", text: $infoIcao, placeholder: "EGSS")
                    infoButton("METAR", "metar")
                    infoButton("TAF", "taf")
                    infoButton("ATIS", "vatatis")
                }
            }
        }
    }

    private func infoButton(_ title: String, _ kind: String) -> some View {
        ActionButton(label: title, minWidth: 0) {
            let icao = infoIcao
            Task { await hoppie.requestInfo(kind, icao: icao) }
        }
        .disabled(infoIcao.trimmingCharacters(in: .whitespaces).count != 4)
        .padding(.top, 14)
    }

    /// The usual VATSIM format: REQUEST PREDEP CLEARANCE <callsign> <type> TO <destination> AT <departure> STAND <stand> ATIS <letter>.
    private var pdcCard: some View {
        Card(title: "Pre-departure clearance") {
            VStack(alignment: .leading, spacing: 12) {
                if let ofp = app.ofp {
                    HStack(spacing: 10) {
                        LabeledField(title: "Stand", text: $stand, placeholder: "225")
                        LabeledField(title: "ATIS letter", text: $atis, placeholder: "K")
                    }
                    Text(pdcText(ofp)).font(.system(size: 13, design: .monospaced)).foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    ActionButton(label: "Request clearance from \(station.isEmpty ? "the station above" : station)", systemImage: "doc.text", minWidth: 0) {
                        let to = station, message = pdcText(ofp)
                        Task { await hoppie.sendTelex(to: to, message) }
                    }
                    .disabled(station.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Text("Load your SimBrief flight to fill the request in.").font(.system(size: 14)).foregroundColor(theme.textSecondary)
                }
            }
        }
    }

    private func pdcText(_ ofp: Ofp) -> String {
        var parts = ["REQUEST PREDEP CLEARANCE", hoppie.callsign.uppercased(), ofp.aircraft.icao, "TO", ofp.destination.icao, "AT", ofp.origin.icao]
        if !stand.trimmingCharacters(in: .whitespaces).isEmpty { parts += ["STAND", stand.uppercased()] }
        if !atis.trimmingCharacters(in: .whitespaces).isEmpty { parts += ["ATIS", atis.uppercased()] }
        return parts.joined(separator: " ")
    }

    // MARK: Messages

    private var messagesCard: some View {
        let list = hoppie.messages.reversed()
        return Card(title: "Messages", accessory: {
            if !hoppie.messages.isEmpty { Button("Clear") { hoppie.clear() }.font(.system(size: 13, weight: .medium)).foregroundColor(Theme.warnOrange) }
        }, content: {
            if hoppie.messages.isEmpty {
                Text("Nothing yet. Messages to and from ATC and the network appear here, newest first.")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            } else {
                VStack(spacing: 8) { ForEach(Array(list)) { message in row(message) } }
            }
        })
    }

    private func row(_ message: HoppieMessage) -> some View {
        let incoming = message.direction == .incoming
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right").font(.system(size: 11, weight: .bold))
                    .foregroundColor(incoming ? Theme.okGreen : Theme.selectedBlue)
                Text("\(incoming ? "FROM" : "TO") \(message.station)").font(.system(size: 12, weight: .bold)).foregroundColor(theme.text)
                Text(message.type.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
                Spacer()
                if message.failed { Text("NOT SENT").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.warnOrange) }
                Text(FlightFormat.time(message.time)).font(.system(size: 12, design: .monospaced)).foregroundColor(theme.textSecondary)
            }
            Text(message.text.isEmpty ? "(no text)" : message.text)
                .font(.system(size: 14, design: .monospaced)).foregroundColor(theme.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if message.needsPilotReply {
                HStack(spacing: 8) {
                    ForEach(["WILCO", "UNABLE", "ROGER", "AFFIRM", "NEGATIVE"].filter { allowed($0, message) }, id: \.self) { answer in
                        ActionButton(label: answer, height: 36) { Task { await hoppie.reply(to: message, answer) } }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(incoming ? theme.pill : theme.pillStrong.opacity(0.5)))
    }

    /// Which answers fit the reply ATC asked for.
    private func allowed(_ answer: String, _ message: HoppieMessage) -> Bool {
        switch message.cpdlcReplyCode ?? "" {
        case "WU": return answer == "WILCO" || answer == "UNABLE"
        case "AN": return answer == "AFFIRM" || answer == "NEGATIVE"
        case "R": return answer == "ROGER"
        default: return true
        }
    }
}

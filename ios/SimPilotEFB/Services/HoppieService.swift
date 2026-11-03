import Foundation
import Security

/// Hoppie's ACARS network (hoppie.nl), used on VATSIM for pre-departure clearances, telexes and CPDLC. Everything is
/// plain HTTPS: a message goes out with a request, incoming ones are collected by polling about once a minute, and
/// only after the first message was sent (the network asks clients not to poll before they have something to say).
/// The logon code is a personal secret (hoppie.nl → Get Logon Code) and is kept in the iPad's Keychain.
struct HoppieMessage: Identifiable, Equatable {
    enum Direction { case incoming, outgoing }

    let id = UUID()
    var time: Date
    var direction: Direction
    /// The other station: the sender of an incoming message, the recipient of an outgoing one.
    var station: String
    /// "telex", "cpdlc", "inforeq", "progress"…
    var type: String
    var packet: String
    var failed = false
    var unread = false

    // CPDLC: "/data2/<message id>/<reference id>/<reply code>/<text>"
    private var cpdlcParts: [String]? {
        guard type == "cpdlc", packet.hasPrefix("/data2/") else { return nil }
        let parts = packet.components(separatedBy: "/") // ["", "data2", id, ref, reply, text…]
        return parts.count >= 6 ? parts : nil
    }

    var cpdlcID: Int? { cpdlcParts.flatMap { Int($0[2]) } }
    /// Replies expected from the pilot ("WU": wilco/unable, "AN": affirm/negative, "R": roger, "Y": any reply).
    var cpdlcReplyCode: String? { cpdlcParts?[4] }

    /// What to show: CPDLC without its header, with "@" as line breaks.
    var text: String {
        guard let parts = cpdlcParts else { return packet }
        return parts[5...].joined(separator: "/").replacingOccurrences(of: "@", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var needsPilotReply: Bool {
        guard direction == .incoming, let code = cpdlcReplyCode else { return false }
        return ["WU", "AN", "R", "Y"].contains(code)
    }
}

enum HoppieProtocol {
    static let endpoint = URL(string: "https://www.hoppie.nl/acars/system/connect.html")!

    enum Failure: LocalizedError {
        case server(String)
        case unexpected

        var errorDescription: String? {
            switch self {
            case let .server(message): return message
            case .unexpected: return "Hoppie's network sent something unexpected."
            }
        }
    }

    /// The reply is `ok`, `error {reason}`, or `ok {FROM TYPE {packet}} {FROM TYPE {packet}} …`.
    static func parse(_ reply: String, now: Date = Date()) throws -> [HoppieMessage] {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("error") {
            let reason = braces(text.dropFirst("error".count)).first ?? text
            throw Failure.server(reason.isEmpty ? "Hoppie's network refused the request." : reason)
        }
        guard text == "ok" || text.hasPrefix("ok ") || text.hasPrefix("ok{") else { throw Failure.unexpected }
        return braces(text.dropFirst(2)).compactMap { group in
            // "FROM TYPE {packet}": the packet is itself braced.
            let parts = group.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 3 else { return nil }
            let packet = parts[2].trimmingCharacters(in: .whitespaces)
            let inner = packet.hasPrefix("{") && packet.hasSuffix("}") ? String(packet.dropFirst().dropLast()) : packet
            return HoppieMessage(time: now, direction: .incoming, station: parts[0].uppercased(), type: parts[1].lowercased(), packet: inner, unread: true)
        }
    }

    /// The contents of each top-level `{…}` group, with nested braces kept.
    static func braces(_ text: Substring) -> [String] {
        var groups: [String] = []
        var depth = 0
        var current = ""
        for ch in text {
            if ch == "{" {
                depth += 1
                if depth == 1 { current = ""; continue }
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { groups.append(current); continue }
                if depth < 0 { depth = 0; continue }
            }
            if depth >= 1 { current.append(ch) }
        }
        return groups
    }

    /// Callsigns and packets are sent as they are; only characters that would break the form are removed.
    static func clean(_ text: String) -> String { text.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")") }

    static func body(logon: String, from: String, to: String, type: String, packet: String) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let fields = [("logon", logon), ("from", from), ("to", to), ("type", type), ("packet", packet)]
        return Data(fields.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&").utf8)
    }
}

/// The logon code lives in the Keychain, not in preferences.
enum SecretStore {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SimPilotEFB", kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

@MainActor
final class HoppieStore: ObservableObject {
    enum LinkState: Equatable {
        case idle
        case working
        case online(Date)
        case failed(String)
    }

    @Published private(set) var messages: [HoppieMessage] = []
    @Published private(set) var state: LinkState = .idle
    /// Polling runs once the first message has been sent (or you went online by hand).
    @Published private(set) var polling = false

    @Published var logon: String { didSet { SecretStore.write("hoppieLogon", logon.trimmingCharacters(in: .whitespaces)) } }
    @Published var callsign: String { didSet { UserDefaults.standard.set(callsign, forKey: "hoppieCallsign") } }

    var unreadCount: Int { messages.filter(\.unread).count }
    var configured: Bool { !logon.trimmingCharacters(in: .whitespaces).isEmpty && !callsign.trimmingCharacters(in: .whitespaces).isEmpty }

    private var pollTask: Task<Void, Never>?
    private var lastSend = Date.distantPast
    private var nextCpdlcID = 1
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        logon = SecretStore.read("hoppieLogon") ?? ""
        callsign = UserDefaults.standard.string(forKey: "hoppieCallsign") ?? ""
    }

    // MARK: Sending

    /// A telex to a station (ATC unit, dispatch, another pilot).
    func sendTelex(to station: String, _ text: String) async {
        await send(to: station, type: "telex", packet: text)
    }

    /// METAR, TAF or VATSIM ATIS from the network's own server: `kind` is "metar", "taf" or "vatatis".
    func requestInfo(_ kind: String, icao: String) async {
        await send(to: "SERVER", type: "inforeq", packet: "\(kind) \(icao.uppercased())")
    }

    /// CPDLC reply to a message of ATC ("WILCO", "UNABLE", "ROGER", "AFFIRM", "NEGATIVE").
    func reply(to message: HoppieMessage, _ answer: String) async {
        guard let id = message.cpdlcID else { return }
        defer { nextCpdlcID += 1 }
        await send(to: message.station, type: "cpdlc", packet: "/data2/\(nextCpdlcID)/\(id)/N/\(answer)")
    }

    /// Asks an ATC station for a CPDLC connection.
    func requestLogon(to station: String) async {
        defer { nextCpdlcID += 1 }
        await send(to: station, type: "cpdlc", packet: "/data2/\(nextCpdlcID)//Y/REQUEST LOGON")
    }

    private func send(to station: String, type: String, packet: String) async {
        guard configured else { state = .failed("Enter your Hoppie logon code and callsign first."); return }
        let to = HoppieProtocol.clean(station).trimmingCharacters(in: .whitespaces).uppercased()
        guard !to.isEmpty else { return }
        // The network asks for at least a couple of seconds between messages.
        let wait = 2 - Date().timeIntervalSince(lastSend)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastSend = Date()
        var entry = HoppieMessage(time: Date(), direction: .outgoing, station: to, type: type, packet: HoppieProtocol.clean(packet))
        state = .working
        do {
            let incoming = try await request(to: to, type: type, packet: entry.packet)
            messages.append(entry)
            messages.append(contentsOf: incoming)
            state = .online(Date())
            startPolling(soon: true)
        } catch {
            entry.failed = true
            messages.append(entry)
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Polling

    /// Goes online without sending anything (to receive what is already waiting).
    func goOnline() { startPolling(soon: true) }

    func goOffline() {
        pollTask?.cancel()
        pollTask = nil
        polling = false
        if case .online = state { state = .idle }
    }

    private func startPolling(soon: Bool) {
        guard configured else { return }
        polling = true
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = soon
            while !Task.isCancelled {
                // Normally once between 45 and 75 s; a little quicker (20 s) right after something was sent.
                let seconds = first ? 20.0 : Double.random(in: 45...75)
                first = false
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    func poll() async {
        guard configured, !(state == .working) else { return }
        do {
            let incoming = try await request(to: callsign.uppercased(), type: "poll", packet: "")
            messages.append(contentsOf: incoming)
            state = .online(Date())
        } catch {
            // A timeout or a busy server: skip this round and try at the next normal time.
            state = .failed(error.localizedDescription)
        }
    }

    func markRead() {
        guard messages.contains(where: \.unread) else { return }
        for i in messages.indices { messages[i].unread = false }
    }

    func clear() { messages = [] }

    private func request(to: String, type: String, packet: String) async throws -> [HoppieMessage] {
        var req = URLRequest(url: HoppieProtocol.endpoint, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("SimPilotEFB/0.1", forHTTPHeaderField: "User-Agent")
        req.httpBody = HoppieProtocol.body(logon: logon.trimmingCharacters(in: .whitespaces), from: callsign.trimmingCharacters(in: .whitespaces).uppercased(),
                                           to: to, type: type, packet: packet)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try HoppieProtocol.parse(String(decoding: data, as: UTF8.self))
    }
}

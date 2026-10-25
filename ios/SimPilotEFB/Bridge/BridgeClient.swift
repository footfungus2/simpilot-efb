import Combine
import Foundation

/// Live ownship position, kept separate so 10 Hz updates only redraw views that show the aircraft.
@MainActor
final class OwnshipStore: ObservableObject {
    @Published private(set) var ownship: Ownship?

    func update(_ o: Ownship?) {
        ownship = o
    }
}

/// Aircraft L:vars the bridge is watching (e.g. the Fenix A320 cockpit), kept separate so their updates only
/// redraw the cockpit panels.
@MainActor
final class AircraftVars: ObservableObject {
    @Published private(set) var values: [String: Double] = [:]

    subscript(_ name: String) -> Double? { values[name] }

    func merge(_ changed: [String: Double]) {
        values.merge(changed) { $1 }
    }

    func reset() {
        if !values.isEmpty { values = [:] }
    }
}

enum ChartEvent {
    case ready(icao: String)
    case progress(icao: String, done: Int, total: Int)
    case error(icao: String, message: String)
}

/// Connection to the SimPilot bridge: WebSocket for live data, HTTP for everything else.
@MainActor
final class BridgeClient: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: BridgeStatus?
    @Published private(set) var lastError: String?
    let ownship = OwnshipStore()
    let chartEvents = PassthroughSubject<ChartEvent, Never>()
    let aircraft = AircraftVars()
    private var watchedVars = Set<String>()
    private var results: [String: CheckedContinuation<String?, Error>] = [:]

    private(set) var host: String?
    private var manualHost: String?
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var reportedInvalidMessage = false
    private let discovery = BridgeDiscovery()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20) // chart PNGs
        return URLSession(configuration: cfg)
    }()

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var baseURL: URL? { host.flatMap { URL(string: "http://\($0)") } }

    /// Connects to `manualHost` ("192.168.1.20:8380"), or discovers the bridge if it's empty.
    func start(manualHost: String?) {
        let trimmed = manualHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        disconnect()
        lastError = nil
        self.manualHost = trimmed.isEmpty ? nil : BridgeAddress.normalize(trimmed)
        if !trimmed.isEmpty, self.manualHost == nil {
            lastError = "Enter the PC's hostname or address, optionally followed by its port (for example 192.168.1.20:8380)."
            DiagnosticLog.record(.warning, "Bridge", "Invalid bridge address; connection not started")
            return
        }
        if let h = self.manualHost {
            connect(to: h)
        } else {
            state = .searching
            DiagnosticLog.record(.info, "Bridge", "Searching for the PC bridge on the local network")
            discovery.start { [weak self] found in
                self?.discovery.stop()
                self?.connect(to: found)
            }
        }
    }

    func send(requestCharts icao: String) {
        send(["t": "requestCharts", "icao": icao])
    }

    /// Asks the bridge to stream these aircraft L:vars (names without "L:"); remembered across reconnects.
    func watch(_ names: [String]) {
        let new = Set(names).subtracting(watchedVars)
        guard !new.isEmpty else { return }
        watchedVars.formUnion(new)
        send(json: ["t": "lvarWatch", "names": Array(new)])
    }

    /// Runs an MSFS RPN snippet (HubHop preset syntax) on the aircraft; `@` in the code is `value`.
    func run(_ code: String, value: Double = 0) {
        send(json: ["t": "lvarRun", "code": code, "value": value])
    }

    struct CommandFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Sends a command with an id and waits for the bridge's `commandResult` (or a timeout).
    @discardableResult
    func command(_ object: [String: Any], timeout: TimeInterval = 8) async throws -> String? {
        guard isConnected else { throw CommandFailure(message: "PC bridge not connected") }
        let id = UUID().uuidString
        var msg = object
        msg["id"] = id
        return try await withCheckedThrowingContinuation { cont in
            results[id] = cont
            send(json: msg)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = self?.results.removeValue(forKey: id) {
                    DiagnosticLog.record(.error, "Aircraft", "Command timed out waiting for the PC bridge")
                    c.resume(throwing: CommandFailure(message: "No answer from the PC bridge"))
                }
            }
        }
    }

    // MARK: HTTP

    struct HTTPError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? { message }
    }

    /// GET a JSON resource. Returns nil for 202/204 (accepted / no content).
    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T? {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base) else {
            throw HTTPError(status: 0, message: "Not connected to the bridge")
        }
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 202 || code == 204 { return nil }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(code)"
            throw HTTPError(status: code, message: msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func data(_ path: String) async throws -> Data {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base) else {
            throw HTTPError(status: 0, message: "Not connected to the bridge")
        }
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPError(status: code, message: "HTTP \(code)") }
        return data
    }

    // MARK: WebSocket

    private func connect(to host: String) {
        self.host = host
        state = .connecting(host)
        DiagnosticLog.record(.info, "Bridge", "Connecting to the PC bridge")
        guard let url = URL(string: "ws://\(host)/ws") else { return }
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.socket === task, !self.isConnected else { return }
            self.lastError = "The PC bridge did not answer. Check its address, firewall and Wi-Fi connection."
            DiagnosticLog.record(.warning, "Bridge", "Connection timed out before the bridge handshake")
            self.scheduleReconnect()
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text): self.handle(Data(text.utf8))
                    case let .data(data): self.handle(data)
                    @unknown default: break
                    }
                    self.receive(on: task)
                case let .failure(error):
                    self.lastError = "Lost the PC bridge connection. Retrying automatically."
                    DiagnosticLog.record(.warning, "Bridge", "WebSocket connection failed; retrying", error: error)
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = BridgeMessage.decode(data) else {
            if !reportedInvalidMessage {
                DiagnosticLog.record(.warning, "Bridge", "Ignored an unsupported or malformed bridge message; check bridge version")
                reportedInvalidMessage = true
            }
            return
        }
        switch msg {
        case let .hello(s):
            handshakeTask?.cancel()
            if let host { state = .connected(host) }
            lastError = nil
            DiagnosticLog.record(.info, "Bridge", "PC bridge connected")
            logStatus(s)
            status = s
            if !watchedVars.isEmpty { send(json: ["t": "lvarWatch", "names": Array(watchedVars)]) }
        case let .status(s):
            guard isConnected else { return }
            if status != s { logStatus(s) }
            if status?.sim.aircraftTitle != s.sim.aircraftTitle || !s.sim.connected {
                aircraft.reset()
                ownship.update(nil)
                // The bridge only streams changes, so values it sent before this reset would never come back.
                if s.sim.connected, !watchedVars.isEmpty { send(json: ["t": "lvarWatch", "names": Array(watchedVars)]) }
            }
            status = s
        case let .lvars(values): aircraft.merge(values)
        case let .commandResult(id, ok, message):
            guard let c = results.removeValue(forKey: id) else { return }
            DiagnosticLog.record(ok ? .info : .error, "Aircraft", ok ? "Bridge confirmed command execution" : "Bridge rejected an aircraft command")
            if ok { c.resume(returning: message) } else { c.resume(throwing: CommandFailure(message: message ?? "Command failed")) }
        case let .ownship(o): ownship.update(o)
        case let .chartsReady(icao):
            DiagnosticLog.record(.info, "Charts", "Bridge finished exporting charts")
            chartEvents.send(.ready(icao: icao))
        case let .chartsProgress(icao, done, total): chartEvents.send(.progress(icao: icao, done: done, total: total))
        case let .chartsError(icao, message):
            DiagnosticLog.record(.error, "Charts", "PC bridge reported a chart export failure; load PC logs for details")
            chartEvents.send(.error(icao: icao, message: message))
        }
    }

    private func logStatus(_ value: BridgeStatus) {
        if status?.sim.connected != value.sim.connected {
            DiagnosticLog.record(value.sim.connected ? .info : .warning, "Simulator", value.sim.connected ? "MSFS connected" : "MSFS not connected")
        }
        if status?.link.connected != value.link.connected {
            DiagnosticLog.record(value.link.connected ? .info : .warning, "Charts", value.link.connected ? "SimPilot Link panel connected" : "SimPilot Link panel not connected")
        }
    }

    private func send(_ object: [String: String]) {
        send(json: object)
    }

    private func send(json object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self, weak socket] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                DiagnosticLog.record(.error, "Bridge", "Couldn't send a message to the PC bridge", error: error)
                self.lastError = "Couldn't send to the PC bridge. Retrying automatically."
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        handshakeTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = nil
        ownship.update(nil)
        aircraft.reset()
        for (_, c) in results { c.resume(throwing: CommandFailure(message: "Lost the connection to the PC bridge")) }
        results = [:]
        reconnectTask?.cancel()
        let target = manualHost
        state = target.map { .connecting($0) } ?? .searching
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.start(manualHost: target)
        }
    }

    private func disconnect() {
        handshakeTask?.cancel()
        handshakeTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        discovery.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        host = nil
        status = nil
        ownship.update(nil)
        reportedInvalidMessage = false
        state = .idle
        aircraft.reset()
        for (_, c) in results { c.resume(throwing: CommandFailure(message: "Disconnected from the PC bridge")) }
        results = [:]
    }
}

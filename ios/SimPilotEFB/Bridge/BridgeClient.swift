import Combine
import CryptoKit
import Foundation
import Security

/// Live ownship position, kept separate so 10 Hz updates only redraw views that show the aircraft.
@MainActor
final class OwnshipStore: ObservableObject {
    @Published private(set) var ownship: Ownship?

    func update(_ o: Ownship?) {
        ownship = o
    }
}

enum BridgeResponseLimit {
    static let json = 16 * 1024 * 1024
    static let image = 32 * 1024 * 1024
    static let webSocket = 4 * 1024 * 1024
}

enum BridgeImageLimit {
    static func supportsDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 12_000 && height <= 12_000 && width <= 40_000_000 / height
    }
}

final class BridgeSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias ResponseStream = AsyncThrowingStream<(Data, URLResponse), Error>
    private struct PendingResponse {
        let maximumBytes: Int
        let result: ResponseStream.Continuation
        var data = Data()
    }

    private let lock = NSLock()
    private var expectedHost: String?
    private var fingerprint: String?
    private var responses: [Int: PendingResponse] = [:]

    func load(_ request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let (replies, result) = ResponseStream.makeStream()
        let task = session.dataTask(with: request)
        lock.withLock {
            responses[task.taskIdentifier] = PendingResponse(maximumBytes: maximumBytes, result: result)
        }
        defer { task.cancel() }
        task.resume()
        var iterator = replies.makeAsyncIterator()
        guard let reply = try await iterator.next() else { throw CancellationError() }
        return reply
    }

    func pin(host: String?, fingerprint: String?) {
        lock.lock()
        expectedHost = host?.lowercased()
        self.fingerprint = fingerprint
        lock.unlock()
    }

    private func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        lock.lock()
        let hostMatches = expectedHost == challenge.protectionSpace.host.lowercased()
        let expectedFingerprint = fingerprint
        lock.unlock()
        guard hostMatches, let expectedFingerprint else { return nil }
        let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return actual == expectedFingerprint ? URLCredential(trust: trust) : nil
    }

    private func answer(_ challenge: URLAuthenticationChallenge, _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = credential(for: challenge) { completionHandler(.useCredential, credential) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        answer(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard task is URLSessionDataTask, let from = task.originalRequest?.url,
              let to = request.url, BridgeAddress.sameOrigin(to, as: from) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        guard let maximum = lock.withLock({ responses[id]?.maximumBytes }) else {
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximum) {
            let result = lock.withLock { responses.removeValue(forKey: id)?.result }
            result?.finish(throwing: Self.responseTooLarge)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result = lock.withLock { () -> ResponseStream.Continuation? in
            let id = dataTask.taskIdentifier
            guard let maximum = responses[id]?.maximumBytes, let buffered = responses[id]?.data.count else { return nil }
            if data.count > maximum - buffered { return responses.removeValue(forKey: id)?.result }
            responses[id]?.data.append(data)
            return nil
        }
        if let result {
            result.finish(throwing: Self.responseTooLarge)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let pending = lock.withLock({ responses.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { pending.result.finish(throwing: error) }
        else if let response = task.response {
            pending.result.yield((pending.data, response))
            pending.result.finish()
        } else {
            pending.result.finish(throwing: URLError(.badServerResponse))
        }
    }

    private static let responseTooLarge = BridgeClient.HTTPError(status: 413, message: "Bridge response exceeded the size limit")
}

/// AI and multiplayer aircraft around the user (the map's TFC layer), as GeoJSON for the map.
@MainActor
final class TrafficStore: ObservableObject {
    @Published private(set) var aircraft: [TrafficAircraft] = []
    /// Changes with every update, so the map knows to push new data.
    @Published private(set) var version = 0
    private(set) var geojson: Data?

    func update(_ list: [TrafficAircraft]) {
        aircraft = list
        geojson = Self.geoJSON(list)
        version += 1
    }

    func clear() {
        guard !aircraft.isEmpty || geojson != nil else { return }
        update([])
    }

    /// "EZY12AB" over its flight level ("FL350" or the altitude in feet below transition); ground traffic is flagged.
    nonisolated static func label(_ a: TrafficAircraft) -> String {
        let name = a.callsign.isEmpty ? "–" : a.callsign
        if a.onGround { return name }
        return "\(name)\n" + (a.altFt >= 6000 ? String(format: "FL%03.0f", (a.altFt / 100).rounded()) : "\(Int((a.altFt / 100).rounded()) * 100) ft")
    }

    nonisolated static func geoJSON(_ list: [TrafficAircraft]) -> Data? {
        guard !list.isEmpty else { return nil }
        let features: [[String: Any]] = list.map { a in
            ["type": "Feature", "geometry": ["type": "Point", "coordinates": [a.lon, a.lat]],
             "properties": ["label": label(a), "hdg": a.hdgDeg, "ground": a.onGround, "id": a.id]]
        }
        return try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
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
    /// An airport's chart list is available.
    case ready(icao: String)
    case error(icao: String, message: String)
    /// One chart's pages were exported from the sim.
    case chartReady(icao: String, guid: String)
    case chartProgress(icao: String, guid: String, done: Int, total: Int)
    case chartError(icao: String, guid: String, message: String)
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
    let traffic = TrafficStore()
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
    private var pairingCode: String? = SecretStore.read("bridgePairingKey")
    private var pairing: BridgePairingCode? { BridgePairingCode.parse(pairingCode) }
    private var pairingKey: String? { pairing?.key }
    private let sessionDelegate = BridgeSessionDelegate()
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20) // chart PNGs
        return URLSession(configuration: cfg, delegate: sessionDelegate, delegateQueue: nil)
    }()

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var baseURL: URL? { host.flatMap { URL(string: "https://\($0)") } }

    /// Connects to the paired bridge at `manualHost` ("192.168.1.20:8387").
    func start(manualHost: String?) {
        let trimmed = manualHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        disconnect()
        lastError = nil
        guard pairing != nil else {
            lastError = "Pair this iPad with the key and certificate fingerprint shown in SimPilot Bridge."
            return
        }
        self.manualHost = trimmed.isEmpty ? nil : BridgeAddress.normalize(trimmed)
        if !trimmed.isEmpty, self.manualHost == nil {
            lastError = "Enter the PC's hostname or address, optionally followed by its port (for example 192.168.1.20:8387)."
            DiagnosticLog.record(.warning, "Bridge", "Invalid bridge address; connection not started")
            return
        }
        if let h = self.manualHost {
            connect(to: h)
        } else {
            lastError = "Enter the PC address shown in SimPilot Bridge before pairing."
        }
    }

    func setPairingKey(_ code: String?) {
        pairingCode = code
        sessionDelegate.pin(host: nil, fingerprint: pairing?.fingerprint)
    }

    /// With a role (origin / destination / alternate) the bridge also exports the flight's own charts ahead of time.
    func send(requestCharts icao: String, role: String? = nil, procedures: [String] = [], runway: String = "") {
        var message: [String: Any] = ["t": "requestCharts", "icao": icao]
        if let role {
            message["role"] = role
            message["procedures"] = Array(procedures.prefix(8))
            if !runway.isEmpty { message["runway"] = runway }
        }
        send(json: message)
    }

    /// Turns the bridge's AI/multiplayer traffic feed on or off.
    func send(trafficWatch on: Bool) {
        send(json: ["t": "trafficWatch", "on": on])
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
        guard let url = bridgeURL(path), let pairingKey else {
            throw HTTPError(status: 0, message: "Not connected to the bridge")
        }
        var request = URLRequest(url: url)
        request.setValue(pairingKey, forHTTPHeaderField: "x-simpilot-token")
        let (data, response) = try await sessionDelegate.load(request, session: session, maximumBytes: BridgeResponseLimit.json)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 202 || code == 204 { return nil }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(code)"
            throw HTTPError(status: code, message: msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func data(_ path: String) async throws -> Data {
        guard let url = bridgeURL(path), let pairingKey else {
            throw HTTPError(status: 0, message: "Not connected to the bridge")
        }
        var request = URLRequest(url: url)
        request.setValue(pairingKey, forHTTPHeaderField: "x-simpilot-token")
        let (data, response) = try await sessionDelegate.load(request, session: session, maximumBytes: BridgeResponseLimit.image)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPError(status: code, message: "HTTP \(code)") }
        return data
    }

    private func bridgeURL(_ path: String) -> URL? {
        guard let base = baseURL, let url = URL(string: path, relativeTo: base)?.absoluteURL,
              BridgeAddress.sameOrigin(url, as: base) else { return nil }
        return url
    }

    // MARK: WebSocket

    private func connect(to host: String) {
        self.host = host
        state = .connecting(host)
        DiagnosticLog.record(.info, "Bridge", "Connecting to the PC bridge")
        guard let url = URL(string: "wss://\(host)/ws"), let pairingKey, let fingerprint = pairing?.fingerprint,
              let serverHost = url.host else { return }
        sessionDelegate.pin(host: serverHost, fingerprint: fingerprint)
        var request = URLRequest(url: url)
        request.setValue(pairingKey, forHTTPHeaderField: "x-simpilot-token")
        let task = session.webSocketTask(with: request)
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
                    case let .string(text):
                        guard text.utf8.count <= BridgeResponseLimit.webSocket else {
                            self.lastError = "The PC bridge sent an oversized message."
                            DiagnosticLog.record(.warning, "Bridge", "Disconnected from the PC bridge after an oversized message")
                            self.scheduleReconnect()
                            return
                        }
                        self.handle(Data(text.utf8))
                    case let .data(data):
                        guard data.count <= BridgeResponseLimit.webSocket else {
                            self.lastError = "The PC bridge sent an oversized message."
                            DiagnosticLog.record(.warning, "Bridge", "Disconnected from the PC bridge after an oversized message")
                            self.scheduleReconnect()
                            return
                        }
                        self.handle(data)
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
                traffic.clear()
                // The bridge only streams changes, so values it sent before this reset would never come back.
                if s.sim.connected, !watchedVars.isEmpty { send(json: ["t": "lvarWatch", "names": Array(watchedVars)]) }
            }
            status = s
        case let .lvars(values): aircraft.merge(values)
        case let .traffic(list): traffic.update(list)
        case let .commandResult(id, ok, message):
            guard let c = results.removeValue(forKey: id) else { return }
            DiagnosticLog.record(ok ? .info : .error, "Aircraft", ok ? "Bridge confirmed command execution" : "Bridge rejected an aircraft command")
            if ok { c.resume(returning: message) } else { c.resume(throwing: CommandFailure(message: message ?? "Command failed")) }
        case let .ownship(o): ownship.update(o)
        case let .chartsReady(icao):
            DiagnosticLog.record(.info, "Charts", "Bridge has the chart list")
            chartEvents.send(.ready(icao: icao))
        case let .chartsError(icao, message):
            DiagnosticLog.record(.error, "Charts", "PC bridge could not get the chart list; load PC logs for details")
            chartEvents.send(.error(icao: icao, message: message))
        case let .chartReady(icao, guid):
            DiagnosticLog.record(.info, "Charts", "Bridge finished exporting a chart")
            chartEvents.send(.chartReady(icao: icao, guid: guid))
        case let .chartProgress(icao, guid, done, total): chartEvents.send(.chartProgress(icao: icao, guid: guid, done: done, total: total))
        case let .chartError(icao, guid, message):
            DiagnosticLog.record(.error, "Charts", "PC bridge reported a chart export failure; load PC logs for details")
            chartEvents.send(.chartError(icao: icao, guid: guid, message: message))
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
        traffic.clear()
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
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        host = nil
        status = nil
        ownship.update(nil)
        traffic.clear()
        reportedInvalidMessage = false
        state = .idle
        aircraft.reset()
        for (_, c) in results { c.resume(throwing: CommandFailure(message: "Disconnected from the PC bridge")) }
        results = [:]
    }
}

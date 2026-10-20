import Combine
import Foundation

/// Live ownship position, kept separate so 10 Hz updates only redraw views that show the aircraft.
@MainActor
final class OwnshipStore: ObservableObject {
    @Published private(set) var ownship: Ownship?
    /// While the demo flight runs, sim updates from the bridge are ignored.
    var demoActive = false {
        didSet { if !demoActive { ownship = nil } }
    }

    func update(_ o: Ownship?) {
        guard !demoActive else { return }
        ownship = o
    }

    func updateFromDemo(_ o: Ownship) {
        guard demoActive else { return }
        ownship = o
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
    let ownship = OwnshipStore()
    let chartEvents = PassthroughSubject<ChartEvent, Never>()

    private(set) var host: String?
    private var manualHost: String?
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
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
        let trimmed = manualHost?.trimmingCharacters(in: .whitespaces) ?? ""
        self.manualHost = trimmed.isEmpty ? nil : (trimmed.contains(":") ? trimmed : "\(trimmed):8380")
        disconnect()
        if let h = self.manualHost {
            connect(to: h)
        } else {
            state = .searching
            discovery.start { [weak self] found in
                self?.discovery.stop()
                self?.connect(to: found)
            }
        }
    }

    func send(requestCharts icao: String) {
        send(["t": "requestCharts", "icao": icao])
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
        guard let url = URL(string: "ws://\(host)/ws") else { return }
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case let .success(message):
                    if case .connecting = self.state, let h = self.host { self.state = .connected(h) }
                    switch message {
                    case let .string(text): self.handle(Data(text.utf8))
                    case let .data(data): self.handle(data)
                    @unknown default: break
                    }
                    self.receive(on: task)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = BridgeMessage.decode(data) else { return }
        switch msg {
        case let .hello(s), let .status(s): status = s
        case let .ownship(o): ownship.update(o)
        case let .chartsReady(icao): chartEvents.send(.ready(icao: icao))
        case let .chartsProgress(icao, done, total): chartEvents.send(.progress(icao: icao, done: done, total: total))
        case let .chartsError(icao, message): chartEvents.send(.error(icao: icao, message: message))
        }
    }

    private func send(_ object: [String: String]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func scheduleReconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = nil
        ownship.update(nil)
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
        reconnectTask?.cancel()
        reconnectTask = nil
        discovery.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = .idle
    }
}

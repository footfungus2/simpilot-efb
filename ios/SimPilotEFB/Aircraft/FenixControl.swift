import Foundation
import SwiftUI

/// Whether the Fenix can be controlled right now, and if not, why.
enum FenixLink: Equatable {
    case noBridge
    case noSim
    case demo
    case staleSim
    case wrongAircraft(String)
    case waiting
    case live

    /// How old the bridge's last aircraft position may be before the sim counts as not sending data.
    static let maxDataAge: TimeInterval = 5

    static func evaluate(bridgeConnected: Bool, simConnected: Bool, aircraftTitle: String?, demoActive: Bool,
                         lastSimData: Date?, hasCockpitValues: Bool, now: Date = Date()) -> FenixLink {
        guard bridgeConnected else { return .noBridge }
        guard simConnected else { return .noSim }
        if demoActive { return .demo }
        guard let last = lastSimData, now.timeIntervalSince(last) <= maxDataAge else { return .staleSim }
        let title = aircraftTitle ?? ""
        guard title.lowercased().contains("fenix") else { return .wrongAircraft(title) }
        return hasCockpitValues ? .live : .waiting
    }

    var isLive: Bool { self == .live }

    var message: String {
        switch self {
        case .noBridge: return "PC bridge not connected"
        case .noSim: return "MSFS isn't running"
        case .demo: return "Demo flight running: stop it in Settings to control the sim"
        case .staleSim: return "No data from the sim in the last few seconds"
        case let .wrongAircraft(t): return "Load the Fenix A320" + (t.isEmpty ? "" : " (now: \(t))")
        case .waiting: return "Waiting for the Fenix cockpit…"
        case .live: return "Fenix A320 · live"
        }
    }
}

/// Sends Fenix commands and follows each one until the sim confirms it, so the UI can show it as pending, done,
/// or failed. A command is only "done" when the value comes back from the simulator.
@MainActor
final class FenixCommander: ObservableObject {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// Keys of controls with a command in flight (variable names, "squawk", "tune1"…).
    @Published private(set) var pending: Set<String> = []
    /// Target value of pending switch changes, so a picker can mark the option it's moving to.
    @Published private(set) var pendingTargets: [String: Int] = [:]
    @Published private(set) var notice: Notice?

    private let bridge: BridgeClient
    private var vars: AircraftVars { bridge.aircraft }
    private let confirmTimeout: TimeInterval = 3

    init(bridge: BridgeClient) {
        self.bridge = bridge
    }

    func isPending(_ key: String) -> Bool { pending.contains(key) }

    /// Sets a switch/selector variable and waits for the sim to report the new position.
    func set(_ v: String, _ n: Int, label: String) {
        guard !pending.contains(v) else { return }
        track(v, target: n, label: label) {
            try await self.bridge.command(["t": "lvarRun", "code": FenixA320.set(v, n)])
            try await self.readback(v, label: label) { Int($0.rounded()) == n }
            return nil
        }
    }

    /// Momentary pushbutton (press + release); confirmed when its press counter (or state) changes in the sim.
    func press(_ v: String, counter: Bool = true, label: String) {
        guard !pending.contains(v) else { return }
        let before = vars[v]
        let c = counter ? FenixA320.counterPress(v) : FenixA320.holdPress(v)
        track(v, label: label) {
            try await self.bridge.command(["t": "lvarRun", "code": c.press])
            try? await Task.sleep(nanoseconds: 120_000_000)
            try await self.bridge.command(["t": "lvarRun", "code": c.release])
            if counter {
                try await self.readback(v, label: label) { $0 != before }
            }
            return nil
        }
    }

    /// One knob click. Not shown as pending (knobs are clicked quickly), but reported if the sim never reacts.
    func step(_ v: String, _ dir: Int, label: String) {
        let before = vars[v]
        Task {
            do {
                try await bridge.command(["t": "lvarRun", "code": dir > 0 ? FenixA320.inc(v) : FenixA320.dec(v)])
                try await readback(v, label: label) { $0 != before }
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    /// Push or pull of an FCU knob (no readable state of its own, so only the bridge's acknowledgement is checked).
    func send(_ code: String, key: String, label: String) {
        guard !pending.contains(key) else { return }
        track(key, label: label) {
            try await self.bridge.command(["t": "lvarRun", "code": code])
            return nil
        }
    }

    /// Types a squawk on the keypad; the bridge checks every key and the final code.
    func squawk(_ code: String) {
        guard !pending.contains("squawk") else { return }
        track("squawk", label: "Squawk", announce: true) {
            try await self.bridge.command(["t": "fenixSquawk", "code": code], timeout: 20)
        }
    }

    /// Tunes an RMP's standby window to `khz` by turning its knobs; the bridge reads the window after every click.
    func tune(rmp: Int, khz: Int) {
        let key = "tune\(rmp)"
        guard !pending.contains(key) else { return }
        track(key, label: "Radio \(rmp)", announce: true) {
            try await self.bridge.command(["t": "fenixTune", "rmp": rmp, "khz": khz], timeout: 45)
        }
    }

    // MARK: Plumbing

    private func track(_ key: String, target: Int? = nil, label: String, announce: Bool = false,
                       _ work: @escaping () async throws -> String?) {
        pending.insert(key)
        if let target { pendingTargets[key] = target }
        Task {
            do {
                let message = try await work()
                if announce { show(message ?? "\(label) done", isError: false) }
            } catch {
                show(error.localizedDescription, isError: true)
            }
            pending.remove(key)
            pendingTargets[key] = nil
        }
    }

    /// Waits until the sim reports a value for `v` that passes `test`.
    private func readback(_ v: String, label: String, _ test: (Double) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(confirmTimeout)
        while Date() < deadline {
            if let value = vars[v], test(value) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BridgeClient.CommandFailure(message: "\(label): the Fenix didn't confirm the change")
    }

    func show(_ text: String, isError: Bool) {
        let n = Notice(text: text, isError: isError)
        notice = n
        Task {
            try? await Task.sleep(nanoseconds: isError ? 6_000_000_000 : 3_000_000_000)
            if notice == n { notice = nil }
        }
    }

    func dismissNotice() { notice = nil }
}

/// Typed standby frequencies: "121.8", "121.800", "121800" → kHz (121800). Nil if not a VHF COM frequency.
enum FrequencyInput {
    static func khz(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        let value: Int
        if s.contains(".") {
            guard let d = Double(s), d.isFinite, (118...136.99).contains(d) else { return nil }
            value = Int((d * 1000).rounded())
        } else {
            guard let n = Int(s), n > 0 else { return nil }
            value = n < 1000 ? n * 1000 : n
        }
        return (118_000...136_990).contains(value) ? value : nil
    }

    /// VATSIM controller frequencies come as "133.700".
    static func khz(vatsim text: String) -> Int? { khz(text) }
}

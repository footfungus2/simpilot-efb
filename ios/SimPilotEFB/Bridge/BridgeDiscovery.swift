import Foundation
import Network

/// Finds the bridge on the LAN via Bonjour (`_simpilot._tcp`) and resolves it to an IPv4 host:port.
final class BridgeDiscovery {
    private var browser: NWBrowser?
    private var resolving: NWConnection?
    private let queue = DispatchQueue(label: "bridge.discovery")

    /// Calls `found` on the main queue with "host:port" for the first bridge that resolves.
    func start(found: @escaping (String) -> Void) {
        stop()
        let browser = NWBrowser(for: .bonjour(type: "_simpilot._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.resolving == nil, let result = results.first else { return }
            self.resolve(result.endpoint, found: found)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving?.cancel()
        resolving = nil
    }

    private func resolve(_ endpoint: NWEndpoint, found: @escaping (String) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4 // a plain IPv4 address is easiest to put in URLs
        }
        let conn = NWConnection(to: endpoint, using: params)
        resolving = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                    let hostString: String
                    switch host {
                    case let .ipv4(addr): hostString = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
                    case let .name(name, _): hostString = name
                    default: hostString = "\(host)"
                    }
                    DispatchQueue.main.async { found("\(hostString):\(port.rawValue)") }
                }
                conn.cancel()
                self?.resolving = nil
            case .failed, .cancelled:
                self?.resolving = nil
            default:
                break
            }
        }
        conn.start(queue: queue)
    }
}

import Foundation

enum BridgeAddress {
    static func sameOrigin(_ url: URL, as base: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() &&
            url.host?.lowercased() == base.host?.lowercased() &&
            url.port == base.port && url.user == nil && url.password == nil
    }

    static func normalize(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URLComponents(string: text.contains("://") ? text : "https://\(text)"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "https"), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        // Earlier SimPilot bridges used 8386 for the iPad; that port now stays loopback-only.
        let port = url.port.map { [8380, 8386].contains($0) ? 8387 : $0 } ?? 8387
        guard (1...65535).contains(port), !host.contains(where: { $0.isWhitespace }) else { return nil }
        return "\(host):\(port)"
    }
}

struct BridgePairingCode: Equatable {
    let key: String
    let fingerprint: String

    static func parse(_ input: String?) -> BridgePairingCode? {
        guard let input else { return nil }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              parts[1].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return BridgePairingCode(key: String(parts[0]), fingerprint: String(parts[1]))
    }
}

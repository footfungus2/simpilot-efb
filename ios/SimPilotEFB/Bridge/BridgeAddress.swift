import Foundation

enum BridgeAddress {
    static func normalize(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URLComponents(string: text.contains("://") ? text : "http://\(text)"),
              url.scheme == "http", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        // Bridges before 0.1.4 build 21 used 8380 (FlyByWire SimBridge's port), so a saved old address moves along.
        let port = url.port.map { $0 == 8380 ? 8386 : $0 } ?? 8386
        guard (1...65535).contains(port), !host.contains(where: { $0.isWhitespace }) else { return nil }
        return "\(host):\(port)"
    }
}

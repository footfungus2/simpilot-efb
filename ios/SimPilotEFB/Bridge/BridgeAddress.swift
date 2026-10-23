import Foundation

enum BridgeAddress {
    static func normalize(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URLComponents(string: text.contains("://") ? text : "http://\(text)"),
              url.scheme == "http", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        let port = url.port ?? 8380
        guard (1...65535).contains(port), !host.contains(where: { $0.isWhitespace }) else { return nil }
        return "\(host):\(port)"
    }
}

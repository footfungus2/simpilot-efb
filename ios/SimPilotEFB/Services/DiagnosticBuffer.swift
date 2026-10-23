import Foundation

enum DiagnosticLevel: String, Codable {
    case info, warning, error
}

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let time: Date
    let level: DiagnosticLevel
    let scope: String
    let message: String
}

/// Session-only, bounded output: no network bodies, credentials or account details.
struct DiagnosticBuffer {
    private(set) var entries: [DiagnosticEntry] = []

    mutating func append(_ level: DiagnosticLevel, _ scope: String, _ message: String, time: Date = Date()) {
        let scope = Self.redact(scope), message = Self.redact(message)
        // Re-loading a PC log snapshot must not evict the original app-side failure.
        guard !entries.contains(where: { $0.time == time && $0.level == level && $0.scope == scope && $0.message == message }) else { return }
        entries.append(DiagnosticEntry(time: time, level: level, scope: scope, message: message))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }

    mutating func clear() { entries.removeAll() }

    static func redact(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s]+"#, with: "[URL]", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?i)\b(bearer\s+|(?:token|password|secret|authorization|api[_-]?key)\s*[:=]\s*)[^\s,;]+"#,
                                       with: "$1[redacted]", options: .regularExpression)
        out = out.replacingOccurrences(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, with: "[email]", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, with: "[address]", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?:/Users/|/home/|[A-Za-z]:\\Users\\)[^\s]+"#, with: "[path]", options: .regularExpression)
        out = out.components(separatedBy: .newlines).joined(separator: " ")
        return String(out.prefix(800))
    }

    func report(summary: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        let header = summary.map(Self.redact).joined(separator: "\n")
        let lines = entries.map { "\(formatter.string(from: $0.time)) [\($0.level.rawValue.uppercased())] \($0.scope): \($0.message)" }
        return ([header, "Session diagnostics (latest 300 entries)"] + lines).joined(separator: "\n")
    }
}

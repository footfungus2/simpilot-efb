import Combine
import Foundation

@MainActor
final class DiagnosticLog: ObservableObject {
    static let shared = DiagnosticLog()
    @Published private(set) var buffer = DiagnosticBuffer()

    nonisolated static func record(_ level: DiagnosticLevel, _ scope: String, _ message: String, error: Error? = nil) {
        // Error descriptions can contain account-specific URLs; retain only their domain and code.
        let detail = error.map { " [\(($0 as NSError).domain):\(($0 as NSError).code)]" } ?? ""
        Task { @MainActor in shared.append(level, scope, message + detail) }
    }

    func append(_ level: DiagnosticLevel, _ scope: String, _ message: String, time: Date = Date()) {
        buffer.append(level, scope, message, time: time)
    }

    func clear() { buffer.clear() }
}

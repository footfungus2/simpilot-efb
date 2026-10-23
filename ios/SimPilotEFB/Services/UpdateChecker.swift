import Combine
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: AppRelease?
    @Published private(set) var checking = false
    @Published private(set) var message: String?
    @Published var dismissed = false
    @Published var installerChoice = UserDefaults.standard.string(forKey: "updateInstaller") ?? "Automatic" {
        didSet { UserDefaults.standard.set(installerChoice, forKey: "updateInstaller") }
    }
    let detectedInstaller = UpdateInstaller.detect(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:])

    var installer: UpdateInstaller? { UpdateInstaller(rawValue: installerChoice) ?? detectedInstaller }
    var installURL: URL? {
        guard let available, let installer else { return nil }
        return available.installURL(using: installer)
    }

    var installed: String {
        "\(Bundle.main.shortVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))"
    }

    func check() async {
        guard !checking else { return }
        checking = true
        message = nil
        DiagnosticLog.record(.info, "Updates", "Checking for updates")
        defer { checking = false }
        do {
            var request = URLRequest(url: AppRelease.manifest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(AppRelease.self, from: data)
            guard release.isValid else { throw URLError(.cannotParseResponse) }
            let build = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
            available = release.isNewer(than: Bundle.main.shortVersion, build: build) ? release : nil
            message = available == nil ? "You're up to date." : nil
            DiagnosticLog.record(.info, "Updates", available == nil ? "Installed build is up to date" : "An optional update is available")
        } catch {
            message = "Couldn't check for updates. Try again when you're online."
            DiagnosticLog.record(.warning, "Updates", "Update check failed; the installed app remains available", error: error)
        }
    }
}

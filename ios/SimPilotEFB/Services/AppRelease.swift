import Foundation

struct AppRelease: Decodable {
    let version: String
    let build: Int

    static let page = URL(string: "https://github.com/footfungus2/simpilot-efb/releases/latest")!
    static let manifest = URL(string: "https://github.com/footfungus2/simpilot-efb/releases/latest/download/update.json")!

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    var isValid: Bool { Self.components(version) != nil && build > 0 }

    func isNewer(than version: String, build: Int) -> Bool {
        guard isValid, let remote = Self.components(self.version), let local = Self.components(version) else { return false }
        for i in 0..<max(remote.count, local.count) {
            let a = i < remote.count ? remote[i] : 0
            let b = i < local.count ? local[i] : 0
            if a != b { return a > b }
        }
        return self.build > build
    }

    func installURL(using installer: UpdateInstaller) -> URL {
        // A build query prevents a replaced release's older IPA being reused from cache.
        var ipa = URLComponents(string: "https://github.com/footfungus2/simpilot-efb/releases/download/v\(version)-build.\(build)/SimPilotEFB.ipa")!
        ipa.queryItems = [URLQueryItem(name: "build", value: String(build))]
        var install = URLComponents()
        install.scheme = installer.scheme
        install.host = "install"
        install.queryItems = [URLQueryItem(name: "url", value: ipa.url!.absoluteString)]
        return install.url!
    }
}

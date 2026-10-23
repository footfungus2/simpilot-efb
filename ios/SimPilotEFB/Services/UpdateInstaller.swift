import Foundation

enum UpdateInstaller: String, CaseIterable {
    case trollStore = "TrollStore"
    case sideStore = "SideStore"

    var scheme: String { self == .sideStore ? "sidestore" : "apple-magnifier" }

    static func detect(bundleURL: URL, info: [String: Any]) -> UpdateInstaller? {
        // TrollStore marks the bundle container, not the .app itself.
        let container = bundleURL.deletingLastPathComponent()
        if ["_TrollStore", "_TrollStoreLite"].contains(where: {
            FileManager.default.fileExists(atPath: container.appendingPathComponent($0).path)
        }) { return .trollStore }

        guard let identifier = info["CFBundleIdentifier"] as? String else { return nil }
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        // SideStore injects this scheme when signing each installed app.
        if types.contains(where: {
            ($0["CFBundleURLSchemes"] as? [String] ?? []).contains("sidestore-\(identifier)")
        }) { return .sideStore }
        return nil
    }
}

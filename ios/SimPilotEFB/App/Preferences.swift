import SwiftUI
import UIKit

// Choices behind Settings → Customization and the map tools. The values live on AppState (persisted in
// UserDefaults); the static `current` readers are for code without access to AppState (Theme, Motion, map style).

/// Colour of selected controls: module switcher, segmented controls, toggles.
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, teal, green, orange, purple, pink

    static let defaultsKey = "accent"
    static var current: AccentChoice { AccentChoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .blue }

    var id: String { rawValue }
    var title: String { self == .blue ? "Blue (mPilot)" : rawValue.capitalized }
    var color: Color { Color(hex: hex) }
    var hex: UInt32 {
        switch self {
        case .blue: return 0x2F6FE4
        case .teal: return 0x1C9AA5
        case .green: return 0x2E9E5B
        case .orange: return 0xE07B2E
        case .purple: return 0x7B5CE0
        case .pink: return 0xD9467E
        }
    }
}

/// How much the interface animates. The iPad's Reduce Motion setting caps `.full` at `.reduced` (see `Motion`).
enum MotionLevel: String, CaseIterable, Identifiable {
    case full, reduced, off

    static let defaultsKey = "motion"
    static var current: MotionLevel { MotionLevel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .full }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Full"
        case .reduced: return "Reduced"
        case .off: return "Off"
        }
    }
}

/// Size of the labels on the enroute and airport map (the AA button and Settings).
enum MapTextSize: String, CaseIterable, Identifiable {
    case small, medium, large, xlarge

    static let defaultsKey = "mapTextSize"
    static var current: MapTextSize { MapTextSize(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .medium }

    var id: String { rawValue }
    /// Factor applied to every text size in the map style.
    var scale: Double {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.2
        case .xlarge: return 1.4
        }
    }
    var shortTitle: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .xlarge: return "XL"
        }
    }
    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Standard"
        case .large: return "Large"
        case .xlarge: return "Extra large"
        }
    }
}

/// Colour of the planned route line on the map.
enum RouteColorChoice: String, CaseIterable, Identifiable {
    case gold, magenta, cyan, white

    static let defaultsKey = "routeColor"
    static var current: RouteColorChoice { RouteColorChoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .gold }

    var id: String { rawValue }
    var title: String { self == .gold ? "Gold (mPilot)" : rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .gold: return 0xE8B04A
        case .magenta: return 0xE04FB0
        case .cyan: return 0x34C6E8
        case .white: return 0xF2F2F2
        }
    }
    var color: Color { Color(hex: hex) }
    /// "#E8B04A" for the map style JSON.
    var cssHex: String { String(format: "#%06X", hex) }
}

/// Which module the app opens on.
enum StartModule: String, CaseIterable, Identifiable {
    case map, charts, aircraft, last

    static let defaultsKey = "startModule"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .map: return "Map"
        case .charts: return "Charts"
        case .aircraft: return "Aircraft"
        case .last: return "Last used"
        }
    }
}

extension Module {
    /// Stored name for "Last used" start module.
    var storageName: String {
        switch self {
        case .map: return "map"
        case .charts: return "charts"
        case .aircraft: return "aircraft"
        }
    }

    init?(storageName: String) {
        switch storageName {
        case "map": self = .map
        case "charts": self = .charts
        case "aircraft": self = .aircraft
        default: return nil
        }
    }
}

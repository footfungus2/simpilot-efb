import SwiftUI
import UIKit

/// Settings → Customization → Theme.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case night, day, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .night: return "Night"
        case .day: return "Day"
        case .system: return "Match iPad"
        }
    }
}

/// Every value on Settings → Customization, so the page can reset them together.
struct CustomizationValues: Equatable {
    var followSystemAppearance = false
    var night = true
    var accent = AccentChoice.blue
    var motion = MotionLevel.full
    var showUtcClock = false
    var mapTextSize = MapTextSize.medium
    var routeColor = RouteColorChoice.gold
    var globeView = true
    var showGraticule = true
    var invertChartsAtNight = true
    var startModule = StartModule.map
    var flightFolderAtLaunch = true

    /// The values a fresh install starts with (keep in step with `AppState.init`).
    static let defaults = CustomizationValues()
}

extension AppState {
    var themeChoice: ThemeChoice {
        get { followSystemAppearance ? .system : night ? .night : .day }
        set {
            switch newValue {
            case .system: followSystemAppearance = true // RootView keeps `night` in step with the iPad
            case .night: followSystemAppearance = false; night = true
            case .day: followSystemAppearance = false; night = false
            }
        }
    }

    /// The colour scheme to force, or nil to follow the iPad (Theme → Match iPad).
    var preferredColorScheme: ColorScheme? {
        followSystemAppearance ? nil : night ? .dark : .light
    }

    var customization: CustomizationValues {
        get {
            CustomizationValues(followSystemAppearance: followSystemAppearance, night: night, accent: accent, motion: motion,
                                showUtcClock: showUtcClock, mapTextSize: mapTextSize, routeColor: routeColor,
                                globeView: globeView, showGraticule: showGraticule, invertChartsAtNight: invertChartsAtNight,
                                startModule: startModule, flightFolderAtLaunch: flightFolderAtLaunch)
        }
        set {
            followSystemAppearance = newValue.followSystemAppearance
            night = newValue.night
            accent = newValue.accent
            motion = newValue.motion
            showUtcClock = newValue.showUtcClock
            mapTextSize = newValue.mapTextSize
            routeColor = newValue.routeColor
            globeView = newValue.globeView
            showGraticule = newValue.showGraticule
            invertChartsAtNight = newValue.invertChartsAtNight
            startModule = newValue.startModule
            flightFolderAtLaunch = newValue.flightFolderAtLaunch
        }
    }
}

/// Pushes the theme choice and accent to the app's UIKit windows.
enum WindowAppearance {
    /// `.preferredColorScheme(nil)` doesn't reliably undo an earlier forced style on iOS 15, so the window override is
    /// set here as well. The window tint gives UIKit pieces (alerts, menus, text cursors) the accent too.
    @MainActor
    static func apply(follow: Bool, night: Bool, accent: AccentChoice) {
        let style: UIUserInterfaceStyle = follow ? .unspecified : night ? .dark : .light
        let tint = UIColor(hex: accent.hex)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.windowLevel == .normal {
                if window.overrideUserInterfaceStyle != style { window.overrideUserInterfaceStyle = style }
                if window.tintColor != tint { window.tintColor = tint }
            }
        }
    }
}

/// A colour picked from swatches (accent, route colour).
protocol SwatchChoice: Hashable, Identifiable {
    var hex: UInt32 { get }
    var title: String { get }
}

extension SwatchChoice {
    var swatchColor: Color { Color(hex: hex) }
    /// Light colours (white) need a dark checkmark and a visible ring.
    var isLight: Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.75
    }
}

extension AccentChoice: SwatchChoice {}
extension RouteColorChoice: SwatchChoice {}

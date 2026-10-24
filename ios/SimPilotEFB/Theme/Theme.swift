import SwiftUI
import UIKit

/// Colours measured from the mPilot screenshots (see docs/design-reference.md).
struct Theme: Equatable {
    let night: Bool
    /// Selected-control colour from Settings → Customization.
    var accent: AccentChoice = AccentChoice.current

    // Chrome
    var bar: Color { night ? Color(hex: 0x22252B) : Color(hex: 0xF2F2F4) }
    var sidebar: Color { night ? Color(hex: 0x2B2E34) : Color(hex: 0xFFFFFF) }
    var pill: Color { night ? Color(hex: 0x2E3138) : Color(hex: 0xE4E5E9) }
    var pillStrong: Color { night ? Color(hex: 0x3A3D44) : Color(hex: 0xD6D8DD) }
    var separator: Color { night ? Color(hex: 0x3A3D44) : Color(hex: 0xD9DADF) }
    var text: Color { night ? .white : Color(hex: 0x1B1D21) }
    var textSecondary: Color { night ? Color(hex: 0x9EA3AB) : Color(hex: 0x6B7079) }
    var overlay: Color { night ? Color(hex: 0x2A2D33).opacity(0.92) : Color.white.opacity(0.92) }

    // Accents
    /// Selected controls (module switcher, segments, toggles): the accent chosen in Settings → Customization,
    /// mPilot blue `#2F6FE4` by default.
    static var selectedBlue: Color { AccentChoice.current.color }
    var accentColor: Color { accent.color }
    static let ownshipBlue = Color(hex: 0x3D8BFF)
    static let okGreen = Color(hex: 0x2FB24F)
    static let warnOrange = Color(hex: 0xE8913A)
    static let originGreen = Color(hex: 0x3FB860)
    static let destinationOrange = Color(hex: 0xF0962E)
    static let alternateMagenta = Color(hex: 0xC85C9A)
    static let route = Color(hex: 0xE8B04A)

    // Map
    var mapBackground: UIColor { night ? UIColor(hex: 0x13202E) : UIColor(hex: 0xFFFFFF) }
    var mapLand: UIColor { night ? UIColor(hex: 0x1F252C) : UIColor(hex: 0xF6F0E4) }
    var mapLakes: UIColor { night ? UIColor(hex: 0x13202E) : UIColor(hex: 0xFFFFFF) }
    var mapGraticule: UIColor { night ? UIColor(hex: 0x2A3440) : UIColor(hex: 0xE6DCCB) }
    var firLine: UIColor { night ? UIColor(hex: 0x3DAA55) : UIColor(hex: 0x2E9A48) }
    var countryLabel: UIColor { night ? UIColor(hex: 0x5E6670) : UIColor(hex: 0x9A8670) }
    var mapAirport: UIColor { UIColor(hex: 0x3D8BFF) }

    // Airport moving map (mPilot AMM: light grey pavement on a pale ground by day, dark at night)
    var ammGround: UIColor { night ? UIColor(hex: 0x3A3F47) : UIColor(hex: 0xF3F3F1) }
    var ammPavement: UIColor { night ? UIColor(hex: 0x575D67) : UIColor(hex: 0xC8C9CB) }
    var ammRunway: UIColor { night ? UIColor(hex: 0x1C1F23) : UIColor(hex: 0x4A4C50) }
    var ammBuilding: UIColor { night ? UIColor(hex: 0x15171A) : UIColor(hex: 0x2E3033) }
    var ammTaxiLine: UIColor { night ? UIColor(hex: 0xE2B73B) : UIColor(hex: 0xE0A800) }
    var ammLabel: UIColor { night ? .white : UIColor(hex: 0x1B1D21) }
    var mapLabel: UIColor { night ? .white : UIColor(hex: 0x1B1D21) }
    var mapLabelHalo: UIColor { night ? UIColor(hex: 0x10161F) : .white }
}

private struct ThemeKey: EnvironmentKey {
    /// Computed, so it carries the accent chosen now rather than at first use.
    static var defaultValue: Theme { Theme(night: true) }
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// The app theme, plus its accent for system controls (toggles, pickers, links, progress views, bar buttons).
    /// Apply at the root and again on sheet content, which doesn't reliably inherit the environment on iOS 15.
    func themed(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .accentColor(theme.accentColor)
            .tint(theme.accentColor)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

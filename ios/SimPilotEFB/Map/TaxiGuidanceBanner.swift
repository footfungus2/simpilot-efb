import CoreLocation
import SwiftUI

/// On the airport map while taxiing: progress along the entered route (done, current, next), the distance to the
/// holding point you're to stop at, and to the stand you were given.
struct TaxiGuidanceBanner: View {
    @Environment(\.theme) private var theme
    let route: [String]
    let progress: TaxiProgress
    let stand: AirportGround.Stand?
    let hold: AirportGround.Hold?
    let position: CLLocationCoordinate2D?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !route.isEmpty { routeRow }
            if let hold { targetRow("HOLD SHORT", hold.label, hold.coordinate, color: Color(hex: 0xFF3B30)) }
            if let stand { targetRow("STAND", stand.ref, stand.coordinate, color: Theme.okGreen) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.overlay))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.separator))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private var routeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("TAXI").font(.system(size: 9, weight: .bold)).foregroundColor(theme.textSecondary)
                ForEach(Array(route.enumerated()), id: \.offset) { i, name in chip(name, index: i) }
            }
            Text(summary).font(.system(size: 12, weight: .medium)).foregroundColor(theme.textSecondary)
        }
    }

    private func chip(_ name: String, index: Int) -> some View {
        let done = index < progress.reached
        let current = index == progress.reached
        return Text(name)
            .font(.system(size: 14, weight: .bold))
            .strikethrough(done)
            .foregroundColor(current ? .white : done ? theme.textSecondary : theme.text)
            .padding(.horizontal, 9).frame(height: 26)
            .background(Capsule().fill(current ? (progress.onRoute ? Theme.okGreen : Theme.warnOrange) : theme.pill))
    }

    private var summary: String {
        let current = route[min(progress.reached, route.count - 1)]
        let next = progress.next(in: route)
        if !progress.onRoute { return progress.reached == 0 ? "Not on \(current) yet" : "Off the route (last on \(current))" }
        return next.map { "On \(current) · next \($0)" } ?? "On \(current) · last taxiway of the route"
    }

    private func targetRow(_ title: String, _ name: String, _ target: CLLocationCoordinate2D, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(theme.textSecondary)
            Text(name).font(.system(size: 14, weight: .bold)).foregroundColor(theme.text).lineLimit(1)
            Spacer(minLength: 6)
            if let position {
                let meters = AirportGround.meters(position, target)
                Text(String(format: "%@ · %03.0f°", meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000),
                            AirportGround.bearing(from: position, to: target)))
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundColor(theme.text)
            }
        }
    }
}

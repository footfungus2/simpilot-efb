import SwiftUI

/// Compact progress strip over the map: next waypoint, top of descent, destination — distance and ETA (UTC).
struct FlightProgressStrip: View {
    @Environment(\.theme) private var theme
    let progress: RouteProgress

    private static let utc: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm'Z'"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            if let next = progress.next { cell("NEXT", next) ; divider }
            if let tod = progress.topOfDescent { cell("DESCENT", tod); divider }
            cell("DEST", progress.destination)
        }
        .padding(.horizontal, 6)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.overlay))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.separator))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private var divider: some View { Rectangle().fill(theme.separator).frame(width: 1, height: 30) }

    private func cell(_ title: String, _ leg: RouteProgress.Leg) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(theme.textSecondary)
                Text(leg.name).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.route)
            }
            HStack(spacing: 8) {
                Text(String(format: "%.0f NM", leg.distanceNm)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                if let eta = leg.eta {
                    Text(Self.utc.string(from: eta)).font(.system(size: 14)).monospacedDigit().foregroundColor(theme.textSecondary)
                }
            }
            .foregroundColor(theme.text)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

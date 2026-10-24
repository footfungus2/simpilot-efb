import CoreLocation
import SwiftUI

struct MapRuler: Equatable {
    struct Point: Equatable {
        var coordinate: CLLocationCoordinate2D
        var label: String

        static func == (a: Point, b: Point) -> Bool {
            a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.label == b.label
        }
    }

    var a: Point?
    var b: Point?
    var followsAircraft = false

    mutating func tap(_ point: Point) {
        if a == nil || b != nil { a = point; b = nil; followsAircraft = false } else { b = point }
    }

    func start(_ ownship: Ownship?) -> Point? {
        if followsAircraft { return ownship.map { Point(coordinate: $0.coordinate, label: "Aircraft") } }
        return a
    }

    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852
    }

    /// Points on the shorter great-circle arc; split at the dateline so the flat map does not draw across the world.
    static func segments(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [[[Double]]] {
        let rad = Double.pi / 180
        let lat = a.latitude * rad, lon = a.longitude * rad
        let latB = b.latitude * rad, lonB = b.longitude * rad
        let angle = acos(min(1, max(-1, sin(lat) * sin(latB) + cos(lat) * cos(latB) * cos(lonB - lon))))
        if angle < 1e-10 { return [[[a.longitude, a.latitude], [a.longitude, a.latitude]]] }
        let bearing = RunwayAwareness.bearing(a, b) * rad
        let steps = max(1, Int(ceil(angle / rad)))
        var lines = [[[a.longitude, a.latitude]]]
        for i in 1...steps {
            let d = angle * Double(i) / Double(steps)
            let phi = asin(min(1, max(-1, sin(lat) * cos(d) + cos(lat) * sin(d) * cos(bearing))))
            let lambda = lon + atan2(sin(bearing) * sin(d) * cos(lat), cos(d) - sin(lat) * sin(phi))
            let p = i == steps ? [b.longitude, b.latitude] : [(lambda / rad + 540).truncatingRemainder(dividingBy: 360) - 180, phi / rad]
            let last = lines[lines.count - 1].last!
            if abs(p[0] - last[0]) > 180 {
                let edge = last[0] > 0 ? 180.0 : -180.0
                let unwrapped = p[0] + (last[0] > 0 ? 360 : -360)
                let y = last[1] + (p[1] - last[1]) * (edge - last[0]) / (unwrapped - last[0])
                lines[lines.count - 1].append([edge, y])
                lines.append([[-edge, y]])
            }
            lines[lines.count - 1].append(p)
        }
        return lines
    }
}

struct RulerCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    let ownship: Ownship?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Measure", systemImage: "ruler").font(.headline)
                Spacer()
                Button { withAnimation(Motion.snappy) { app.rulerActive = false } } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .accessibilityLabel("Close ruler")
            }
            if let a = app.ruler.start(ownship), let b = app.ruler.b {
                let nm = MapRuler.distanceNM(a.coordinate, b.coordinate)
                let bearing = RunwayAwareness.bearing(a.coordinate, b.coordinate)
                Text("\(a.label) → \(b.label)").font(.subheadline).lineLimit(1)
                Text(String(format: "%.1f NM · %03.0f° T", nm, bearing)).font(.title3.monospacedDigit())
                HStack {
                    Text(String(format: "%.1f km", nm * 1.852))
                    if let o = ownship {
                        Text(String(format: "%03.0f° M", (bearing - o.magVarDeg + 360).truncatingRemainder(dividingBy: 360)))
                        if o.gsKt > 50 { Text(String(format: "%.0f min", nm / o.gsKt * 60)) }
                    }
                }
                .font(.caption).foregroundColor(theme.textSecondary)
            } else {
                Text(app.ruler.followsAircraft && ownship == nil ? "Aircraft position unavailable." : app.ruler.a == nil ? "Tap two points on the map." : "Tap the end point.")
                    .font(.subheadline).foregroundColor(theme.textSecondary)
            }
            HStack(spacing: 16) {
                Button("From aircraft") {
                    guard let ownship else { return }
                    app.ruler.a = MapRuler.Point(coordinate: ownship.coordinate, label: "Aircraft")
                    app.ruler.followsAircraft = true
                }.frame(minHeight: 44).contentShape(Rectangle()).disabled(ownship == nil)
                Button("Swap") {
                    let first = app.ruler.start(ownship)
                    app.ruler.a = app.ruler.b
                    app.ruler.b = first
                    app.ruler.followsAircraft = false
                }.frame(minHeight: 44).contentShape(Rectangle()).disabled(app.ruler.b == nil)
                Button("Clear") { app.ruler = MapRuler() }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .font(.subheadline)
        }
        .buttonStyle(.pressableSoft)
        .foregroundColor(theme.text)
        .padding(16)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.overlay))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.separator))
    }
}

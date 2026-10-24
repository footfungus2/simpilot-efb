import CoreLocation
import SwiftUI

/// mPilot-style vertical profile: FL axis, gold planned profile with waypoint triangles and
/// slanted labels, and the ownship placed by along-track distance.
struct VerticalProfileView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @State private var drawn: CGFloat = 0
    let ofp: Ofp
    let ownship: Ownship?

    var body: some View {
        ProfileCanvas(ofp: ofp, ownship: ownship, theme: theme, routeColor: app.routeColor.color, reveal: drawn)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.overlay))
            .onAppear { withAnimation(Motion.layout) { drawn = 1 } }
    }
}

private struct ProfileCanvas: View, Animatable {
    let ofp: Ofp
    let ownship: Ownship?
    let theme: Theme
    let routeColor: Color
    var reveal: CGFloat
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    private let levels = [100, 200, 300, 400, 500]
    private let maxFt = 52_000.0
    private let axisWidth: CGFloat = 52
    private let labelHeight: CGFloat = 54

    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: axisWidth, y: labelHeight, width: size.width - axisWidth - 16, height: size.height - labelHeight - 14)
            let total = max(ofp.navlog.last?.cumNm ?? ofp.distanceNm, 1)
            func x(_ nm: Double) -> CGFloat { plot.minX + CGFloat(nm / total) * plot.width }
            func y(_ ft: Double) -> CGFloat { plot.maxY - CGFloat(min(ft, maxFt) / maxFt) * plot.height }

            // FL grid
            for fl in levels {
                let yy = y(Double(fl) * 100)
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: yy))
                line.addLine(to: CGPoint(x: plot.maxX, y: yy))
                ctx.stroke(line, with: .color(theme.separator), lineWidth: 1)
                ctx.draw(Text("FL\(fl)").font(.system(size: 11)).foregroundColor(theme.textSecondary),
                         at: CGPoint(x: axisWidth / 2 + 4, y: yy), anchor: .center)
            }

            // Planned profile: origin → navlog → destination
            var pts: [CGPoint] = [CGPoint(x: x(0), y: y(ofp.origin.elevFt))]
            pts += ofp.navlog.map { CGPoint(x: x($0.cumNm), y: y($0.altFt)) }
            pts.append(CGPoint(x: x(total), y: y(ofp.destination.elevFt)))
            var profile = Path()
            profile.addLines(pts)
            ctx.stroke(profile.trimmedPath(from: 0, to: reveal), with: .color(routeColor), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

            // Waypoints: triangle + slanted label, thinned so labels don't collide.
            var lastLabelX = -CGFloat.infinity
            for fix in ofp.navlog where fix.type != "apt" {
                let p = CGPoint(x: x(fix.cumNm), y: y(fix.altFt))
                var tri = Path()
                tri.move(to: CGPoint(x: p.x, y: p.y - 6))
                tri.addLine(to: CGPoint(x: p.x + 5, y: p.y + 3))
                tri.addLine(to: CGPoint(x: p.x - 5, y: p.y + 3))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(theme.sidebar))
                ctx.stroke(tri, with: .color(routeColor), lineWidth: 1.4)

                guard p.x - lastLabelX > 14 else { continue }
                lastLabelX = p.x
                var labelCtx = ctx
                labelCtx.translateBy(x: p.x + 2, y: min(p.y, plot.minY) - 10)
                labelCtx.rotate(by: .degrees(-60))
                labelCtx.draw(Text(fix.ident).font(.system(size: 10, weight: .semibold)).foregroundColor(theme.text),
                              at: .zero, anchor: .leading)
            }

            // Ownship
            if let o = ownship, let along = RouteProgress.alongTrackNm(ofp: ofp, o) {
                let p = CGPoint(x: x(along), y: y(o.altFt))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)), with: .color(Theme.ownshipBlue.opacity(0.3)))
                var plane = Path()
                plane.move(to: CGPoint(x: p.x + 9, y: p.y))
                plane.addLine(to: CGPoint(x: p.x - 7, y: p.y - 6))
                plane.addLine(to: CGPoint(x: p.x - 3, y: p.y))
                plane.addLine(to: CGPoint(x: p.x - 7, y: p.y + 6))
                plane.closeSubpath()
                ctx.fill(plane, with: .color(Theme.ownshipBlue))
                var vline = Path()
                vline.move(to: CGPoint(x: p.x, y: plot.minY))
                vline.addLine(to: CGPoint(x: p.x, y: plot.maxY))
                ctx.stroke(vline, with: .color(Theme.ownshipBlue.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

}

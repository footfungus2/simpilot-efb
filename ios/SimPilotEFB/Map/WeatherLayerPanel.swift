import SwiftUI

/// The WX popover in the map's layer box: METAR indicators and SIGMETs, load status and a legend.
struct WeatherLayerPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var store: WeatherStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weather").font(.headline)
            Toggle(isOn: animated(\.wxMetars)) {
                label("METAR indicators", app.wxOffsetHours == 0
                      ? "Ceiling and visibility at airports, observed now"
                      : "TAF forecast for the weather time")
            }
            Toggle(isOn: animated(\.wxSigmets)) {
                label("SIGMETs", "Thunderstorms, turbulence, icing, volcanic ash and more")
            }

            statusLine

            if app.wxOffsetHours > 0 && (app.wxMetars || app.wxSigmets) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundColor(theme.accentColor)
                    Text(offsetNote).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .transition(.opacity)
            }

            Divider()
            legend
        }
        .padding()
        .frame(width: 340)
        .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
        .animation(Motion.smooth, value: app.wxOffsetHours)
    }

    /// "Forecast for 14:00Z (+3 h) — TAF-based. Change in the top bar."
    private var offsetNote: String {
        let time = "\(WeatherDecoder.time(app.weatherTime)) (+\(app.wxOffsetHours) h)"
        return app.wxMetars ? "Forecast for \(time) — TAF-based. Change in the top bar."
                            : "SIGMETs valid at \(time). Change in the top bar."
    }

    private func animated(_ key: ReferenceWritableKeyPath<AppState, Bool>) -> Binding<Bool> {
        Binding(get: { app[keyPath: key] }, set: { on in withAnimation(Motion.snappy) { app[keyPath: key] = on } })
    }

    private func label(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Status

    @ViewBuilder private var statusLine: some View {
        let feeds = store.neededFeeds
        let states = feeds.map { store.status[$0] ?? WeatherStore.FeedStatus() }
        if feeds.isEmpty {
            Text("Turn on a layer to load live weather from aviationweather.gov.")
                .font(.caption).foregroundColor(.secondary)
        } else if let failed = feeds.first(where: { store.status[$0]?.error != nil }), let message = store.status[failed]?.error {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warnOrange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failed.rawValue) unavailable. \(message)")
                    if let updated = store.status[failed]?.updated {
                        Text("Showing data from \(WeatherDecoder.time(updated)).").foregroundColor(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Retry") { store.retry() }
                    .font(.caption.weight(.semibold))
                    .disabled(states.contains(where: \.loading))
            }
            .font(.caption)
        } else if states.allSatisfy({ $0.updated == nil }) {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading \(feeds.map(\.rawValue).joined(separator: " and "))…").foregroundColor(.secondary)
            }
            .font(.caption)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.okGreen)
                Text(summary(feeds)).foregroundColor(.secondary).monospacedDigit()
                if states.contains(where: \.loading) { ProgressView().scaleEffect(0.7) }
            }
            .font(.caption)
        }
    }

    /// "Updated 10:42Z · 5 012 stations · 14 SIGMETs"
    private func summary(_ feeds: [WeatherStore.Feed]) -> String {
        var parts: [String] = []
        if let updated = feeds.compactMap({ store.status[$0]?.updated }).min() {
            parts.append("Updated \(WeatherDecoder.time(updated))")
        }
        if store.showMetars { parts.append("\(Self.count(store.indicatorCount)) stations") }
        if store.showSigmets { parts.append("\(Self.count(store.sigmetCount)) SIGMET\(store.sigmetCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Thin-space thousands: "5 012".
    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{2009}"
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("LEGEND").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            ForEach([WxCategory.green, .amber, .red, .unknown], id: \.self) { c in
                legendRow(Image(uiImage: MapIcons.metarIndicator(c)), c.meaning)
            }
            if app.wxOffsetHours > 0 {
                legendRow(Image(uiImage: MapIcons.metarIndicator(.green, temporary: .red)),
                          "Right half: temporarily worse (TEMPO or PROB group)")
            }
            legendRow(Image(systemName: "square.fill").foregroundColor(Color(hex: 0xB45CE8)), "SIGMET area, labelled with hazard and levels")
            Text("Tap an indicator for the airport's METAR and TAF, or a SIGMET for its details.")
                .font(.caption).foregroundColor(.secondary).padding(.top, 2)
        }
    }

    private func legendRow<Icon: View>(_ icon: Icon, _ text: String) -> some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Details for a tapped SIGMET: hazard, FIR, levels, validity, movement and the raw text.
struct SigmetInfoCard: View {
    @Environment(\.theme) private var theme
    let sigmet: Sigmet
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(sigmet.hazard.isEmpty ? "WX" : sigmet.hazard)
                    .font(.system(size: sigmet.hazard.count > 3 ? 10 : 13, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x9B3FD1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 13)).foregroundColor(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(theme.textSecondary)
                        .frame(width: 28, height: 28).background(Circle().fill(theme.pill))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(theme.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
                    ForEach(rows, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
                            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(theme.text)
                        }
                    }
                }
                if !sigmet.raw.isEmpty {
                    Text(sigmet.raw).font(.system(size: 12, design: .monospaced)).foregroundColor(theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
                }
            }
            .padding(16)
        }
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    /// "Embedded thunderstorms", "Severe turbulence"; volcanic ash and cyclones keep their name for the subtitle.
    private var title: String {
        guard let q = sigmet.qualifierName, sigmet.hazard != "VA", sigmet.hazard != "TC" else { return sigmet.hazardName }
        return "\(q) \(sigmet.hazardName.lowercased())"
    }

    private var subtitle: String {
        var parts = [sigmet.firName ?? sigmet.firId]
        if sigmet.hazard == "VA" || sigmet.hazard == "TC", let q = sigmet.qualifierName { parts.insert(q, at: 0) }
        if let series = sigmet.series { parts.append("SIGMET \(series)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = []
        if !sigmet.levels.isEmpty { out.append(("Levels", sigmet.levels)) }
        out.append(("Valid", "\(WeatherDecoder.time(sigmet.validFrom)) – \(WeatherDecoder.time(sigmet.validTo))"))
        let left = sigmet.validTo.timeIntervalSinceNow
        out.append(("Ends", left <= 0 ? "Expired" : left < 3600 ? "In \(Int(left / 60)) min" : String(format: "In %d h %02d min", Int(left / 3600), Int(left / 60) % 60)))
        if let movement = sigmet.movement { out.append(("Movement", movement)) }
        if let change = sigmet.change {
            out.append(("Trend", ["INTSF": "Intensifying", "WKN": "Weakening", "NC": "No change"][change] ?? change))
        }
        return out
    }
}

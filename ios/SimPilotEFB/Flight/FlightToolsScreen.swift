import SwiftUI

/// "Flight" module: the pilot's working pages for one flight, in the EFB's own card style. Briefing cards for the
/// departure and arrival (runway, procedures, ATIS, QNH, minima), an ATC clearance pad with Pencil notes, editable
/// checklists whose progress is kept per flight, and the logbook. Everything here works without the PC.
struct FlightToolsScreen: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        FlightToolsPanels(store: app.flightTools)
    }
}

private enum FlightPage: String, CaseIterable, Identifiable {
    case briefing = "Briefing", clearances = "Clearances", checklists = "Checklists", fuel = "Fuel", logbook = "Logbook", documents = "Documents"
    var id: String { rawValue }
}

private struct FlightToolsPanels: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject var store: FlightToolsStore
    @AppStorage("flightPage") private var pageRaw = FlightPage.briefing.rawValue

    private var page: FlightPage { FlightPage(rawValue: pageRaw) ?? .briefing }
    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(theme.bar)
                .zIndex(1)
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .top) {
                    switch page {
                    case .briefing: BriefingPage(store: store, compact: compact).transition(.screen)
                    case .clearances: ClearancePage(store: store, compact: compact).transition(.screen)
                    case .checklists: ChecklistPage(store: store, compact: compact).transition(.screen)
                    case .fuel: FuelPage(store: store, compact: compact).transition(.screen)
                    case .logbook: LogbookPage(store: store, compact: compact).transition(.screen)
                    case .documents: DocumentsPage(store: store, compact: compact).transition(.screen)
                    }
                }
                .padding(compact ? 12 : 20)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .animation(Motion.smooth, value: page)
            }
        }
        .background(theme.bar)
    }

    @ViewBuilder private var header: some View {
        let picker = Segmented(options: FlightPage.allCases.map { ($0.rawValue, $0.rawValue) }, value: pageRaw) { pageRaw = $0 }
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                title
                picker
            }
            .padding(12)
        } else {
            HStack(spacing: 14) {
                title
                picker.frame(maxWidth: 760)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Flight").font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
            if let ofp = app.ofp {
                Text("\(ofp.callsign) · \(ofp.origin.icao) → \(ofp.destination.icao)")
                    .font(.system(size: 12)).foregroundColor(theme.textSecondary)
            }
        }
        .fixedSize()
    }
}

// MARK: - Shared building blocks

/// Small caption over a text field in the EFB's pill style.
struct LabeledField: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var text: String
    var placeholder = ""
    var keyboard: UIKeyboardType = .default
    var capitalized = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.5)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalized ? .characters : .sentences)
                .disableAutocorrection(true)
                .font(.system(size: 16, weight: .medium)).foregroundColor(theme.text)
                .padding(.horizontal, 10).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
        }
    }
}

/// Label over a value, for the facts on a briefing card.
struct Fact: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.textSecondary).tracking(0.5)
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundColor(theme.text)
                .lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Times in UTC ("1423Z"), durations ("1h 05m"): what pilots read and write.
enum FlightFormat {
    private static let utc = TimeZone(identifier: "UTC")!

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = format
        return f
    }

    static func time(_ date: Date?) -> String { date.map { formatter("HH:mm'Z'").string(from: $0) } ?? "–" }
    static func day(_ date: Date?) -> String { date.map { formatter("d MMM yyyy").string(from: $0) } ?? "–" }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "–" }
        let minutes = Int((seconds / 60).rounded())
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    static var utcZone: TimeZone { utc }
}

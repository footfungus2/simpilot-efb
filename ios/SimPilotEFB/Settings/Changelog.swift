import SwiftUI

/// What changed in each release, newest first. Add an entry (with a new `id`) for every release: the app shows the newest
/// one once after an update, and Settings → What's new lists them all.
struct ChangelogEntry: Identifiable {
    enum Kind: String {
        case added = "Added", changed = "Changed", removed = "Removed", fixed = "Fixed"

        var symbol: String {
            switch self {
            case .added: return "plus.circle.fill"
            case .changed: return "arrow.triangle.2.circlepath.circle.fill"
            case .removed: return "minus.circle.fill"
            case .fixed: return "wrench.and.screwdriver.fill"
            }
        }

        var color: Color {
            switch self {
            case .added: return Theme.okGreen
            case .changed: return Theme.ownshipBlue
            case .removed: return Color(hex: 0xE5534B)
            case .fixed: return Theme.warnOrange
            }
        }
    }

    struct Section: Identifiable {
        var id: String { kind.rawValue }
        let kind: Kind
        let items: [String]
    }

    let id: String
    let version: String
    let date: String
    let summary: String
    let sections: [Section]
}

enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(id: "0.1.2", version: "0.1.2", date: "November 2026", summary: "Waypoint altitudes on the route and a self-updating PC bridge.", sections: [
            .init(kind: .added, items: [
                "Route waypoints show their planned altitude, colour-coded by phase (climb green, cruise cyan, descent orange), with T/C and T/D markers; switch it off in NAV",
                "SimPilot Bridge for the PC is now an app with a status window, tray icon, start-with-Windows option and a Check for updates button that installs updates itself",
            ]),
        ]),
        ChangelogEntry(id: "0.1.0", version: "0.1.0", date: "November 2026", summary: "First release.", sections: [
            .init(kind: .added, items: [
                "Flight screen (checklist icon, bottom bar): departure and arrival briefing with live QNH, wind and VATSIM ATIS, ATC clearance pad with Pencil notes, editable checklists, fuel against the SimBrief plan, logbook, PDF documents and Hoppie ACARS",
                "Edit Flight: set the runway and SID/STAR in use; the charts follow",
                "Taxi guidance: stand lead-in, named holding points, and your taxi route drawn as the line you will drive, greyed as you taxi",
                "Map layers: radar (RainViewer), sim traffic (TFC), grid MORA and airway names along your route",
                "Starred and recent charts across airports",
                "Flight charts are exported from the sim ahead of time while SimPilot Link is open",
                "This What's new screen",
            ]),
            .init(kind: .changed, items: [
                "Charts from the sim are captured sharper and checked tile by tile; SimPilot Bridge and SimPilot Link must be updated together",
                "SimPilot Bridge uses port 8386 (FlyByWire SimBridge uses 8380)",
            ]),
            .init(kind: .removed, items: [
                "The demo flight and the generated placeholder charts",
            ]),
        ]),
    ]

    static var latest: ChangelogEntry? { entries.first }

    private static let seenKey = "lastSeenChangelog"

    /// The entry to show once after an update: nil on a fresh install (nothing is new to someone who has just started) and
    /// once it has been seen.
    static func unseen(freshInstall: Bool, defaults: UserDefaults = .standard) -> ChangelogEntry? {
        guard let latest else { return nil }
        let seen = defaults.string(forKey: seenKey)
        if seen == nil && freshInstall {
            defaults.set(latest.id, forKey: seenKey)
            return nil
        }
        return seen == latest.id ? nil : latest
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        if let latest { defaults.set(latest.id, forKey: seenKey) }
    }
}

/// The list of changes, grouped as Added / Changed / Removed / Fixed.
struct ChangelogView: View {
    @Environment(\.presentationMode) private var presentationMode
    var entries: [ChangelogEntry]
    var title = "What's new"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Version \(entry.version)").font(.system(size: 22, weight: .bold))
                                Spacer()
                                Text(entry.date).font(.system(size: 13)).foregroundColor(.secondary)
                            }
                            Text(entry.summary).font(.system(size: 15)).foregroundColor(.secondary)
                            ForEach(entry.sections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(section.kind.rawValue, systemImage: section.kind.symbol)
                                        .font(.system(size: 15, weight: .semibold)).foregroundColor(section.kind.color)
                                    ForEach(section.items, id: \.self) { item in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("•").foregroundColor(section.kind.color)
                                            Text(item).fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.system(size: 15))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

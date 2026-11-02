import SwiftUI

/// Flight history. Takeoffs and landings are recorded by themselves while the app is connected to the sim (via the
/// PC bridge); block times, notes and anything the app missed can be typed in. The route and aircraft of the loaded
/// flight are saved with each entry.
struct LogbookPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var store: FlightToolsStore
    var compact: Bool

    @State private var editing: LogEntry?
    @State private var editingIsNew = false

    private var entries: [LogEntry] { store.data.log.sorted { $0.sortDate > $1.sortDate } }

    var body: some View {
        VStack(spacing: 16) {
            summaryCard
            if entries.isEmpty {
                Card(title: "Flights") {
                    Text("No flights yet. Takeoffs and landings are logged automatically while the sim is connected, or add a flight by hand.")
                        .font(.system(size: 14)).foregroundColor(theme.textSecondary)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(entries) { entry in row(entry) }
                }
            }
        }
        .sheet(item: $editing) { entry in
            LogEntryEditor(entry: entry, isNew: editingIsNew) { saved in
                store.upsert(saved)
            } onDelete: {
                store.removeLog(entry.id)
            }
        }
    }

    private var summaryCard: some View {
        let air = entries.compactMap(\.airSeconds).reduce(0, +)
        let block = entries.compactMap(\.blockSeconds).reduce(0, +)
        return Card(title: "Logbook", accessory: {
            ActionButton(label: "Add flight", systemImage: "plus", minWidth: 0) {
                var entry = LogEntry()
                if let ofp = app.ofp {
                    entry.callsign = ofp.callsign
                    entry.origin = ofp.origin.icao
                    entry.destination = ofp.destination.icao
                    entry.aircraft = ofp.aircraft.name
                    entry.route = ofp.route
                }
                editingIsNew = true
                editing = entry
            }
        }, content: {
            HStack(spacing: 12) {
                Fact(label: "Flights", value: "\(entries.count)")
                Fact(label: "Air time", value: FlightFormat.duration(air == 0 ? nil : air))
                Fact(label: "Block time", value: FlightFormat.duration(block == 0 ? nil : block))
            }
        })
    }

    private func row(_ entry: LogEntry) -> some View {
        Button {
            editingIsNew = false
            editing = entry
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(entry.origin.isEmpty ? "????" : entry.origin) → \(entry.destination.isEmpty ? "????" : entry.destination)")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(theme.text)
                    if !entry.callsign.isEmpty {
                        Text(entry.callsign).font(.system(size: 14)).foregroundColor(theme.textSecondary)
                    }
                    Spacer()
                    Text(FlightFormat.day(entry.sortDate == .distantPast ? nil : entry.sortDate))
                        .font(.system(size: 13)).foregroundColor(theme.textSecondary)
                }
                if !entry.aircraft.isEmpty {
                    Text(entry.aircraft).font(.system(size: 13)).foregroundColor(theme.textSecondary).lineLimit(1)
                }
                HStack(spacing: 14) {
                    time("OFF", entry.blockOff)
                    time("T/O", entry.takeoff)
                    time("LDG", entry.landing)
                    time("ON", entry.blockOn)
                    Spacer()
                    Text("Air \(FlightFormat.duration(entry.airSeconds))  ·  Block \(FlightFormat.duration(entry.blockSeconds))")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary)
                }
                if !entry.notes.isEmpty {
                    Text(entry.notes).font(.system(size: 13)).foregroundColor(theme.textSecondary).lineLimit(2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.sidebar))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99, dim: 0.9))
    }

    private func time(_ label: String, _ date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(theme.textSecondary)
            Text(FlightFormat.time(date)).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(theme.text)
        }
    }
}

/// Edit one logbook entry: every time can be set, corrected or cleared (all in UTC).
private struct LogEntryEditor: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var draft: LogEntry
    let isNew: Bool
    let onSave: (LogEntry) -> Void
    let onDelete: () -> Void

    init(entry: LogEntry, isNew: Bool, onSave: @escaping (LogEntry) -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: entry)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Flight")) {
                    TextField("Callsign", text: $draft.callsign).textInputAutocapitalization(.characters).disableAutocorrection(true)
                    TextField("From (ICAO)", text: $draft.origin).textInputAutocapitalization(.characters).disableAutocorrection(true)
                    TextField("To (ICAO)", text: $draft.destination).textInputAutocapitalization(.characters).disableAutocorrection(true)
                    TextField("Aircraft", text: $draft.aircraft).disableAutocorrection(true)
                }
                Section(header: Text("Times (UTC)")) {
                    DateRow(title: "Off blocks", date: $draft.blockOff)
                    DateRow(title: "Takeoff", date: $draft.takeoff)
                    DateRow(title: "Landing", date: $draft.landing)
                    DateRow(title: "On blocks", date: $draft.blockOn)
                }
                Section(header: Text("Route")) {
                    TextEditor(text: $draft.route).frame(minHeight: 60).font(.system(size: 14, design: .monospaced))
                }
                Section(header: Text("Notes")) {
                    TextEditor(text: $draft.notes).frame(minHeight: 100)
                }
                if !isNew {
                    Section {
                        Button("Delete this flight", role: .destructive) {
                            onDelete()
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Flight" : "Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.origin = draft.origin.trimmingCharacters(in: .whitespaces).uppercased()
                        draft.destination = draft.destination.trimmingCharacters(in: .whitespaces).uppercased()
                        draft.callsign = draft.callsign.trimmingCharacters(in: .whitespaces).uppercased()
                        draft.automatic = draft.automatic && !isNew
                        onSave(draft)
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// A date that may be unset: "Set to now" when empty, a UTC date picker with a clear button once set.
private struct DateRow: View {
    let title: String
    @Binding var date: Date?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let value = date {
                DatePicker("", selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .environment(\.timeZone, FlightFormat.utcZone)
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(title)")
            } else {
                Button("Set to now") { date = Date() }.buttonStyle(.borderless)
            }
        }
    }
}

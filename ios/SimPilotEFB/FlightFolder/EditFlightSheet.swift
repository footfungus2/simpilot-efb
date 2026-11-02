import SwiftUI

/// Flight Folder → Edit Flight: the runway and SID/STAR actually in use. On VATSIM (and with live ATC) they often
/// differ from the SimBrief plan. The choice drives the briefing, which charts open first and which charts the
/// bridge exports ahead of time. Empty fields mean "as planned".
struct EditFlightSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode
    @State private var edit = FlightEdit()
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                if let ofp = app.ofp {
                    Section(header: Text("Departure \(ofp.origin.icao)"),
                            footer: Text("SimBrief plan: runway \(plan(ofp.origin.planRwy)), SID \(plan(app.ofpProcedures(at: ofp.origin.icao).first))")) {
                        TextField("Runway (e.g. 22)", text: $edit.originRunway).textInputAutocapitalization(.characters).disableAutocorrection(true)
                        TextField("SID (e.g. CLN5S)", text: $edit.sid).textInputAutocapitalization(.characters).disableAutocorrection(true)
                    }
                    Section(header: Text("Arrival \(ofp.destination.icao)"),
                            footer: Text("SimBrief plan: runway \(plan(ofp.destination.planRwy)), STAR \(plan(app.ofpProcedures(at: ofp.destination.icao).first))")) {
                        TextField("Runway (e.g. 22)", text: $edit.destinationRunway).textInputAutocapitalization(.characters).disableAutocorrection(true)
                        TextField("STAR (e.g. LAM1A)", text: $edit.star).textInputAutocapitalization(.characters).disableAutocorrection(true)
                    }
                    if let error {
                        Section { Text(error).foregroundColor(.red) }
                    }
                    Section {
                        Button("Reset to the SimBrief plan", role: .destructive) { edit = FlightEdit(); error = nil }
                            .disabled(edit.isEmpty)
                    }
                } else {
                    Text("Load a SimBrief flight first.").foregroundColor(.secondary)
                }
            }
            .navigationTitle("Edit Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(app.ofp == nil) }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { edit = app.flightTools.edit(app.flightKey) }
    }

    private func plan(_ value: String?) -> String { (value ?? "").isEmpty ? "–" : value! }

    private func save() {
        var cleaned = edit
        cleaned.originRunway = Self.runway(edit.originRunway)
        cleaned.destinationRunway = Self.runway(edit.destinationRunway)
        cleaned.sid = edit.sid.trimmingCharacters(in: .whitespaces).uppercased()
        cleaned.star = edit.star.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.isRunway(cleaned.originRunway), Self.isRunway(cleaned.destinationRunway) else {
            error = "Enter a runway like 04, 4 or 22L."
            return
        }
        app.flightTools.setEdit(cleaned, flight: app.flightKey)
        app.requestFlightCharts() // the bridge exports the charts of the runway and procedures now in use
        presentationMode.wrappedValue.dismiss()
    }

    /// "rwy 4l" → "04L".
    static func runway(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        for prefix in ["RWY", "RW"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if s.prefix(while: \.isNumber).count == 1 { s = "0" + s }
        return s
    }

    static func isRunway(_ text: String) -> Bool {
        text.isEmpty || text.range(of: "^(0[1-9]|[12][0-9]|3[0-6])[LCR]?$", options: .regularExpression) != nil
    }
}

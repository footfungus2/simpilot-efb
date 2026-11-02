import PencilKit
import SwiftUI

/// ATC clearance pad: quick fields for what ATC just said (cleared altitude, heading, speed, squawk, next
/// frequency), a timestamped history of the instructions, and a Pencil scratchpad. Kept per flight.
struct ClearancePage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var store: FlightToolsStore
    var compact: Bool

    @State private var draft = ClearanceEntry()
    @State private var erasing = false
    @State private var clearToken = 0
    @State private var confirmClear = false

    private var flight: String { app.flightKey }

    var body: some View {
        VStack(spacing: 16) {
            entryCard
            AdaptiveStack(compact: compact) {
                historyCard
                scratchCard
            }
        }
        .alert(isPresented: $confirmClear) {
            Alert(title: Text("Clear the clearance history?"), message: Text("The logged instructions of this flight are removed."),
                  primaryButton: .destructive(Text("Clear")) { store.clearClearances(flight: flight) }, secondaryButton: .cancel())
        }
    }

    private var entryCard: some View {
        Card(title: "New clearance", accessory: {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(FlightFormat.time(context.date)).font(.system(size: 13, weight: .medium)).foregroundColor(theme.textSecondary)
            }
        }, content: {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .top)], spacing: 10) {
                    LabeledField(title: "Altitude", text: $draft.altitude, placeholder: "FL240")
                    LabeledField(title: "Heading", text: digits($draft.heading, 3), placeholder: "270", keyboard: .numberPad)
                    LabeledField(title: "Speed", text: $draft.speed, placeholder: "250", keyboard: .numbersAndPunctuation)
                    LabeledField(title: "Squawk", text: digits($draft.squawk, 4), placeholder: "4521", keyboard: .numberPad)
                    LabeledField(title: "Next frequency", text: $draft.frequency, placeholder: "121.800", keyboard: .decimalPad)
                }
                LabeledField(title: "Note", text: $draft.note, placeholder: "Hold short, expect direct…", capitalized: false)
                HStack(spacing: 10) {
                    ActionButton(label: "Log clearance", systemImage: "plus", prominent: true, minWidth: 0) { log() }
                        .disabled(draft.isEmpty)
                    ActionButton(label: "Clear fields", minWidth: 0) { draft = ClearanceEntry() }
                        .disabled(draft.isEmpty)
                }
            }
        })
    }

    private var historyCard: some View {
        let entries = store.clearances(flight)
        return Card(title: "History", accessory: {
            if !entries.isEmpty {
                Button("Clear all") { confirmClear = true }
                    .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.warnOrange)
            }
        }, content: {
            if entries.isEmpty {
                Text("Instructions you log appear here with the time, newest first.")
                    .font(.system(size: 14)).foregroundColor(theme.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in row(entry) }
                }
            }
        })
    }

    private func row(_ entry: ClearanceEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(FlightFormat.time(entry.time)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.textSecondary).frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary(entry)).font(.system(size: 15, weight: .semibold)).foregroundColor(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.system(size: 13)).foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button { store.removeClearance(entry.id, flight: flight) } label: {
                Image(systemName: "trash").font(.system(size: 14)).foregroundColor(theme.textSecondary).frame(width: 36, height: 36)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Delete this clearance")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.pill))
    }

    private func summary(_ e: ClearanceEntry) -> String {
        var parts: [String] = []
        if !e.altitude.isEmpty { parts.append("ALT \(e.altitude)") }
        if !e.heading.isEmpty { parts.append("HDG \(e.heading)") }
        if !e.speed.isEmpty { parts.append("SPD \(e.speed)") }
        if !e.squawk.isEmpty { parts.append("SQK \(e.squawk)") }
        if !e.frequency.isEmpty { parts.append("FREQ \(e.frequency)") }
        return parts.isEmpty ? "Note" : parts.joined(separator: " · ")
    }

    private var scratchCard: some View {
        Card(title: "Pencil scratchpad", accessory: {
            HStack(spacing: 8) {
                Button { erasing = false } label: { toolIcon("pencil.tip", active: !erasing) }
                    .buttonStyle(.pressable).accessibilityLabel("Pen")
                Button { erasing = true } label: { toolIcon("eraser", active: erasing) }
                    .buttonStyle(.pressable).accessibilityLabel("Eraser")
                Button { clearToken += 1 } label: { toolIcon("trash", active: false) }
                    .buttonStyle(.pressable).accessibilityLabel("Clear the scratchpad")
            }
        }, content: {
            ScratchCanvas(key: flight, erasing: erasing, clearToken: clearToken)
                .frame(height: 300)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.pill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        })
    }

    private func toolIcon(_ name: String, active: Bool) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .medium))
            .foregroundColor(active ? .white : theme.text)
            .frame(width: 34, height: 34)
            .background(Circle().fill(active ? Theme.selectedBlue : theme.pill))
    }

    private func log() {
        var entry = draft
        entry.time = Date()
        store.addClearance(entry, flight: flight)
        draft = ClearanceEntry()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Keeps only digits (and at most `limit` of them): squawks and headings.
    private func digits(_ text: Binding<String>, _ limit: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue },
                set: { text.wrappedValue = String($0.filter(\.isNumber).prefix(limit)) })
    }
}

/// Free drawing area for quick notes with the Apple Pencil (or a finger), saved per flight.
struct ScratchCanvas: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let key: String
    var erasing: Bool
    var clearToken: Int

    func makeUIView(context: Context) -> PKCanvasView {
        let view = PKCanvasView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.drawingPolicy = .anyInput
        view.delegate = context.coordinator
        context.coordinator.load(into: view, key: key)
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        // PencilKit shows black ink as white in a dark interface, so the notes stay readable at night.
        view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        view.tool = erasing ? PKEraserTool(.vector) : PKInkingTool(.pen, color: .black, width: 3)
        let coordinator = context.coordinator
        if coordinator.key != key { coordinator.load(into: view, key: key) }
        if coordinator.clearToken != clearToken {
            coordinator.clearToken = clearToken
            view.drawing = PKDrawing() // the delegate saves the empty drawing, which deletes the file
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(key: key, clearToken: clearToken) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var key: String
        var clearToken: Int
        private var loading = false

        init(key: String, clearToken: Int) {
            self.key = key
            self.clearToken = clearToken
        }

        private static func storeKey(_ key: String) -> String { "scratch-\(key)" }

        func load(into view: PKCanvasView, key: String) {
            self.key = key
            loading = true
            view.drawing = AnnotationStore.load(Self.storeKey(key)) ?? PKDrawing()
            loading = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !loading else { return }
            AnnotationStore.save(canvasView.drawing, key: Self.storeKey(key))
        }
    }
}

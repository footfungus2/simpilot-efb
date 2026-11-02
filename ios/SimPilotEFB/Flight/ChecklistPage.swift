import SwiftUI

/// Aircraft checklists you tick by hand. Progress is kept per flight (so the next flight starts clean), and the
/// lists themselves are editable: rename, add, remove, or restore the defaults.
struct ChecklistPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var store: FlightToolsStore
    var compact: Bool

    @AppStorage("selectedChecklist") private var selectedRaw = ""
    @State private var editing = false
    @State private var confirmRestore = false

    private var flight: String { app.flightKey }
    private var lists: [Checklist] { store.data.checklists }
    private var selected: Checklist? { lists.first { $0.id.uuidString == selectedRaw } ?? lists.first }

    var body: some View {
        VStack(spacing: 16) {
            chips
            if let list = selected {
                listCard(list)
            } else {
                Card(title: "Checklists") {
                    Text("No checklists. Add one or restore the defaults.").font(.system(size: 14)).foregroundColor(theme.textSecondary)
                }
            }
            controls
        }
        .alert(isPresented: $confirmRestore) {
            Alert(title: Text("Restore the default checklists?"), message: Text("Your own checklists and edits are replaced. Progress of ticked items is kept only for items that still exist."),
                  primaryButton: .destructive(Text("Restore")) { store.restoreDefaultChecklists(); selectedRaw = "" }, secondaryButton: .cancel())
        }
    }

    // MARK: Pieces

    private var chips: some View {
        let ticked = store.ticked(flight)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(lists) { list in
                    let done = list.items.filter { ticked.contains($0.id.uuidString) }.count
                    let complete = !list.items.isEmpty && done == list.items.count
                    let isSelected = list.id == selected?.id
                    Button { selectedRaw = list.id.uuidString } label: {
                        HStack(spacing: 6) {
                            if complete { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(isSelected ? .white : Theme.okGreen) }
                            Text(list.name).font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            Text("\(done)/\(list.items.count)").font(.system(size: 12)).opacity(0.7).monospacedDigit()
                        }
                        .foregroundColor(isSelected ? .white : theme.text)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(Capsule().fill(isSelected ? Theme.selectedBlue : theme.pill))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("\(list.name), \(done) of \(list.items.count) done")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func listCard(_ list: Checklist) -> some View {
        let ticked = store.ticked(flight)
        let done = list.items.filter { ticked.contains($0.id.uuidString) }.count
        let complete = !list.items.isEmpty && done == list.items.count
        return Card(title: editing ? "Editing" : list.name, accessory: {
            Text("\(done) of \(list.items.count)").font(.system(size: 13, weight: .medium)).foregroundColor(complete ? Theme.okGreen : theme.textSecondary)
        }, content: {
            VStack(alignment: .leading, spacing: 8) {
                if editing {
                    LabeledField(title: "List name", text: nameBinding(list.id), capitalized: false)
                    ForEach(list.items) { item in editRow(list.id, item) }
                    ActionButton(label: "Add item", systemImage: "plus", minWidth: 0) { addItem(to: list.id) }
                } else {
                    ProgressBar(value: list.items.isEmpty ? 0 : Double(done) / Double(list.items.count), complete: complete)
                    ForEach(list.items) { item in tickRow(item, ticked: ticked.contains(item.id.uuidString)) }
                    if complete, let next = nextList(after: list) {
                        ActionButton(label: "Next: \(next.name)", systemImage: "arrow.right", prominent: true, minWidth: 0) { selectedRaw = next.id.uuidString }
                    }
                }
            }
        })
    }

    private func tickRow(_ item: ChecklistItem, ticked: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Motion.snappy) { store.toggle(item, flight: flight) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundColor(ticked ? Theme.okGreen : theme.textSecondary)
                Text(item.challenge).font(.system(size: 16, weight: .medium)).foregroundColor(theme.text)
                Spacer(minLength: 8)
                Text(item.response).font(.system(size: 15, weight: .semibold)).foregroundColor(ticked ? Theme.okGreen : theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 9).fill(ticked ? Theme.okGreen.opacity(0.12) : theme.pill))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.98, dim: 0.85))
        .accessibilityLabel("\(item.challenge), \(item.response)")
        .accessibilityValue(ticked ? "done" : "not done")
    }

    private func editRow(_ list: UUID, _ item: ChecklistItem) -> some View {
        HStack(spacing: 8) {
            LabeledField(title: "Item", text: itemBinding(list, item.id, \.challenge), capitalized: false)
            LabeledField(title: "Response", text: itemBinding(list, item.id, \.response))
            Button { removeItem(item.id, from: list) } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 22)).foregroundColor(Theme.warnOrange).frame(width: 40, height: 40)
            }
            .buttonStyle(.pressable)
            .padding(.top, 14)
            .accessibilityLabel("Remove \(item.challenge)")
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ActionButton(label: editing ? "Done" : "Edit lists", systemImage: editing ? "checkmark" : "pencil", prominent: editing, minWidth: 0) {
                    withAnimation(Motion.snappy) { editing.toggle() }
                }
                if let list = selected, !editing {
                    ActionButton(label: "Reset this list", systemImage: "arrow.counterclockwise", minWidth: 0) {
                        withAnimation(Motion.snappy) { store.resetTicks(list, flight: flight) }
                    }
                }
            }
            if editing {
                HStack(spacing: 10) {
                    ActionButton(label: "New list", systemImage: "plus", minWidth: 0) {
                        store.addChecklist()
                        selectedRaw = store.data.checklists.last?.id.uuidString ?? ""
                    }
                    if let list = selected {
                        ActionButton(label: "Delete list", systemImage: "trash", minWidth: 0) {
                            store.removeChecklist(list.id)
                            selectedRaw = ""
                        }
                    }
                    ActionButton(label: "Restore defaults", minWidth: 0) { confirmRestore = true }
                }
            }
        }
    }

    // MARK: Editing

    private func nextList(after list: Checklist) -> Checklist? {
        guard let i = lists.firstIndex(where: { $0.id == list.id }), i + 1 < lists.count else { return nil }
        return lists[i + 1]
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { lists.first { $0.id == id }?.name ?? "" },
                set: { value in if let i = store.data.checklists.firstIndex(where: { $0.id == id }) { store.data.checklists[i].name = value } })
    }

    private func itemBinding(_ list: UUID, _ item: UUID, _ keyPath: WritableKeyPath<ChecklistItem, String>) -> Binding<String> {
        Binding(get: { lists.first { $0.id == list }?.items.first { $0.id == item }?[keyPath: keyPath] ?? "" },
                set: { value in
                    guard let l = store.data.checklists.firstIndex(where: { $0.id == list }),
                          let i = store.data.checklists[l].items.firstIndex(where: { $0.id == item }) else { return }
                    store.data.checklists[l].items[i][keyPath: keyPath] = value
                })
    }

    private func addItem(to list: UUID) {
        guard let l = store.data.checklists.firstIndex(where: { $0.id == list }) else { return }
        store.data.checklists[l].items.append(ChecklistItem(challenge: "New item", response: "CHECKED"))
    }

    private func removeItem(_ item: UUID, from list: UUID) {
        guard let l = store.data.checklists.firstIndex(where: { $0.id == list }) else { return }
        store.data.checklists[l].items.removeAll { $0.id == item }
    }
}

private struct ProgressBar: View {
    @Environment(\.theme) private var theme
    var value: Double
    var complete: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.pill)
                Capsule().fill(complete ? Theme.okGreen : Theme.selectedBlue).frame(width: max(6, geo.size.width * CGFloat(value)))
            }
        }
        .frame(height: 6)
        .animation(Motion.smooth, value: value)
        .accessibilityHidden(true)
    }
}

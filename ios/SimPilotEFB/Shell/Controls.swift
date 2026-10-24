import SwiftUI

/// Round 36pt chrome button (hamburger, search) from the mPilot top bar.
struct RoundIconButton: View {
    @Environment(\.theme) private var theme
    let systemName: String
    var tint: Color?
    var fill: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint ?? theme.text)
                .frame(width: 36, height: 36)
                .background(Circle().fill(fill ?? theme.pill))
        }
        .buttonStyle(.pressable)
        .animation(Motion.smooth, value: tint)
        .animation(Motion.smooth, value: fill)
    }
}

/// Grouped pill container used for the centre/right top-bar clusters and toolbar groups.
struct PillGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background(Capsule().fill(theme.pill))
    }
}

/// Icon button inside a PillGroup; `selected` shows the blue round fill used for the active module.
/// Pass a `selectionNamespace` (one selected icon per namespace) and the fill becomes one circle that slides between
/// the icons of the group; without it the fill fades in place.
struct PillIcon: View {
    @Environment(\.theme) private var theme
    let systemName: String
    var selected = false
    var label: String?
    var selectionNamespace: Namespace.ID?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName).font(.system(size: 16, weight: .medium))
                if let label { Text(label).font(.system(size: 15, weight: .regular)).monospacedDigit() }
            }
            .foregroundColor(selected ? .white : theme.text)
            .frame(minWidth: 32, minHeight: 32)
            .padding(.horizontal, label == nil ? 0 : 6)
            .background(selectionFill)
        }
        .buttonStyle(.pressable)
        .animation(Motion.snappy, value: selected)
    }

    @ViewBuilder private var selectionFill: some View {
        if label != nil {
            EmptyView() // text pills (e.g. the clock) have no round fill
        } else if let selectionNamespace {
            if selected {
                Circle().fill(Theme.selectedBlue)
                    .frame(width: 32, height: 32)
                    .matchedGeometryEffect(id: "pillSelection", in: selectionNamespace)
            }
        } else {
            Circle().fill(selected ? Theme.selectedBlue : Color.clear).frame(width: 32, height: 32)
        }
    }
}

/// Wide grey pill button ("Edit Flight", "Add Alternate").
struct GreyPillButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.pillStrong))
        }
        .buttonStyle(.pressableSoft)
    }
}

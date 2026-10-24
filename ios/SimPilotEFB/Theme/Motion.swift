import SwiftUI
import UIKit

/// Shared animation curves, so the whole app moves the same way. Each curve is nil with animations off and a short
/// ease with reduced motion, so call sites use them unconditionally:
/// `withAnimation(Motion.snappy) { … }`, `.animation(Motion.smooth, value: x)`, `.transition(.card)`.
/// iOS 15: springs are `.spring(response:dampingFraction:)`; no `.bouncy`/`.snappy` presets, no `symbolEffect`,
/// no `contentTransition`, no `PhaseAnimator`.
enum Motion {
    /// Settings → Customization → Animations, capped at `.reduced` by the iPad's Reduce Motion setting.
    static var level: MotionLevel {
        let chosen = MotionLevel.current
        if chosen == .full && UIAccessibility.isReduceMotionEnabled { return .reduced }
        return chosen
    }

    /// True when things may move, scale or bounce (not just fade).
    static var allowsMovement: Bool { level == .full }

    /// Selection changes, toggles and small state flips: quick, no visible overshoot.
    static var snappy: Animation? { curve(.spring(response: 0.3, dampingFraction: 0.86)) }
    /// Cards, chips and banners arriving: a touch of overshoot.
    static var bouncy: Animation? { curve(.spring(response: 0.42, dampingFraction: 0.74)) }
    /// Cross-fades and colour changes.
    static var smooth: Animation? { curve(.easeInOut(duration: 0.26)) }
    /// Big layout changes: sidebar, split view, module switch, bottom sheets.
    static var layout: Animation? { curve(.spring(response: 0.46, dampingFraction: 0.88)) }
    /// Button press feedback.
    static var press: Animation? { curve(.spring(response: 0.2, dampingFraction: 0.7)) }

    /// Delay for the n-th item of a staggered entrance (0 unless full motion).
    static func stagger(_ index: Int, step: Double = 0.035) -> Double {
        allowsMovement ? Double(min(max(index, 0), 10)) * step : 0
    }

    private static func curve(_ full: Animation) -> Animation? {
        switch level {
        case .full: return full
        case .reduced: return .easeInOut(duration: 0.18)
        case .off: return nil
        }
    }
}

extension AnyTransition {
    /// Info cards and popover-like panels: fade in while scaling up slightly from their top edge.
    static var card: AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).combined(with: .offset(y: -6)),
                           removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }

    /// Banners dropping in from the top (runway banner, update banner, notices).
    static var dropDown: AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        return .move(edge: .top).combined(with: .opacity)
    }

    /// Bottom sheets and chips rising from the bottom (vertical profile, chart-overlay chip).
    static var riseUp: AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    /// Sliding in from an edge (sidebar, side panels); plain fade with reduced motion.
    static func slide(from edge: Edge) -> AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        return .move(edge: edge).combined(with: .opacity)
    }

    /// Small badges and indicators popping in.
    static var pop: AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        return .scale(scale: 0.6).combined(with: .opacity)
    }

    /// Whole-screen content swaps (module switch, chart page change): fade with a hint of scale.
    static var screen: AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.985)),
                           removal: .opacity)
    }

    /// Paged content (onboarding steps): the new page comes in a little from the side it lies on while the old one
    /// leaves the other way. Plain cross-fade with reduced motion.
    static func pageStep(forward: Bool) -> AnyTransition {
        guard Motion.allowsMovement else { return .opacity }
        let shift: CGFloat = 36
        return .asymmetric(insertion: .offset(x: forward ? shift : -shift).combined(with: .opacity),
                           removal: .offset(x: forward ? -shift : shift).combined(with: .opacity))
    }
}

/// Press feedback for chrome buttons: a quick scale-down and dim that springs back on release.
/// Use instead of `.plain` for tappable icons, pills and cards. Disabled buttons fade to
/// `pressableDisabledOpacity` (0.4) unless `disabledOpacity` says otherwise (1 keeps a label that shows its own
/// busy state, e.g. a spinner, at full strength).
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    var dim: Double = 0.75
    var disabledOpacity: Double?

    func makeBody(configuration: Configuration) -> some View {
        PressableLabel(configuration: configuration, scale: scale, dim: dim, disabledOpacity: disabledOpacity)
    }
}

private struct PressableLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.pressableDisabledOpacity) private var defaultDisabledOpacity
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    let dim: Double
    let disabledOpacity: Double?

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(pressed && Motion.allowsMovement ? scale : 1)
            .opacity(isEnabled ? (pressed ? dim : 1) : disabledOpacity ?? defaultDisabledOpacity)
            .animation(Motion.press, value: pressed)
            .animation(Motion.smooth, value: isEnabled)
    }
}

private struct PressableDisabledOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 0.4
}

extension EnvironmentValues {
    /// How far disabled `.pressable` buttons fade. A panel that already dims itself as a whole while disabled
    /// sets 1, so its buttons aren't dimmed twice.
    var pressableDisabledOpacity: Double {
        get { self[PressableDisabledOpacityKey.self] }
        set { self[PressableDisabledOpacityKey.self] = newValue }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    /// Gentler press for large targets (rows, cards, wide pills).
    static var pressableSoft: PressableButtonStyle { PressableButtonStyle(scale: 0.97, dim: 0.8) }
}

extension View {
    /// Loading-skeleton highlight sweeping across the view (static when motion is reduced or off).
    func shimmer(active: Bool = true) -> some View { modifier(ShimmerModifier(active: active)) }

    /// Gentle breathing loop for "searching / connecting" indicators.
    func pulse(active: Bool) -> some View { modifier(PulseModifier(active: active)) }

    /// Staggered entrance: the view fades and lifts in when it first appears, `index` steps after the first item
    /// (`Motion.stagger`, capped at 10). Decided when the view is created: with `active` false (e.g. rows that are
    /// part of a screen that's already cross-fading in) it simply shows. Fade only with reduced motion.
    func staggeredEntrance(_ index: Int, active: Bool = true) -> some View {
        modifier(StaggeredEntrance(index: index, active: active))
    }

    /// Cross-fades the view's content when `value` changes now and then. While it changes faster than about twice
    /// a second (a knob held down, live data) it updates in place, so counting never smears.
    func crossfadeOnChange<V: Hashable>(of value: V) -> some View {
        modifier(CrossfadeOnChange(value: value))
    }
}

private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @State private var shown: Bool

    init(index: Int, active: Bool) {
        self.index = index
        _shown = State(initialValue: !active || Motion.level == .off)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || !Motion.allowsMovement ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.snappy?.delay(Motion.stagger(index))) { shown = true }
            }
    }
}

private struct CrossfadeOnChange<V: Hashable>: ViewModifier {
    let value: V
    @State private var lastChange = Date.distantPast

    func body(content: Content) -> some View {
        // Read before onChange records this change, so it measures the gap since the previous one.
        let calm = Date().timeIntervalSince(lastChange) > 0.45
        ZStack {
            content
                .id(value)
                .transition(.opacity)
        }
        .animation(calm ? Motion.smooth : nil, value: value)
        .onChange(of: value) { _ in lastChange = Date() }
    }
}

/// Rounded placeholder for content that is still loading; shimmers while visible. A nil width or height fills
/// the space offered.
struct SkeletonBlock: View {
    @Environment(\.theme) private var theme
    var width: CGFloat?
    var height: CGFloat? = 12
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(theme.pillStrong)
            .frame(width: width, height: height)
            .shimmer()
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                if active && Motion.allowsMovement {
                    LinearGradient(colors: [.clear, Color.white.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(geo.size.width * 0.5, 40))
                        .offset(x: phase * geo.size.width)
                        .onAppear {
                            phase = -1
                            // Next pass: restarts cleanly on a second appearance and stays out of the transaction
                            // inserting the view (a repeat-forever started there can latch onto its layout).
                            DispatchQueue.main.async {
                                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.5 }
                            }
                        }
                }
            }
            .mask(content)
            .allowsHitTesting(false)
        )
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var dimmed = false
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.45 : 1)
            .scaleEffect(dimmed && Motion.allowsMovement ? 0.92 : 1)
            .onAppear(perform: update)
            .onChange(of: active) { _ in update() }
    }

    private func update() {
        generation += 1
        guard active && Motion.level != .off else {
            withAnimation(Motion.smooth) { dimmed = false }
            return
        }
        // Start from the bright state on the next pass, so the loop restarts after the view reappears and stays
        // out of the transaction inserting it; a newer update (pulse switched off meanwhile) wins.
        let started = generation
        dimmed = false
        DispatchQueue.main.async {
            guard generation == started else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
        }
    }
}

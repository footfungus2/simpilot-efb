import SwiftUI

struct OnboardingView: View {
    @Environment(\.theme) private var theme
    let onFinish: () -> Void
    @State private var step = 0
    /// Direction of the current page turn, so pages slide the way you're going.
    @State private var forward = true

    private let pages = [
        Page(symbol: "airplane", title: "Your flight at a glance",
             detail: "SimPilot brings route planning, maps, charts, weather and VATSIM tools to your iPad."),
        Page(symbol: "doc.text", title: "Load your SimBrief flight",
             detail: "Open Settings → SimBrief and enter your username or pilot ID. Maps, weather and VATSIM work without the simulator."),
        Page(symbol: "wifi", title: "Connect to MSFS 2024",
             detail: "On your PC, open github.com/footfungus2/simpilot-efb/releases, download SimPilot-for-PC.zip, extract it and open the SimPilot for PC folder. Double-click SimPilot Bridge and leave it open. Keep both devices on the same network, and allow the iPad's Local Network prompt. For charts, follow the optional panel steps in Read me.txt or Help."),
        Page(symbol: "map", title: "Explore and get help",
             detail: "Use the bottom bar to switch between Map, Charts and Aircraft. Live charts and Fenix controls need the bridge. Settings has optional updates and Diagnostics if something goes wrong.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SimPilot EFB")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.text)
                Spacer()
                Button("Skip", action: onFinish)
                    .buttonStyle(.pressable)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.selectedBlue)
                    .accessibilityHint("Close the introduction and open the app")
            }

            Spacer(minLength: 32)

            // One page at a time; it slides in from the side you're heading to, its parts arriving one after another.
            ZStack {
                page(step)
                    .id(step)
                    .transition(.pageStep(forward: forward))
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 32)

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Theme.selectedBlue : theme.separator)
                        .frame(width: index == step ? 24 : 8, height: 8)
                }
            }
            .animation(Motion.snappy, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(pages.count)")
            .padding(.bottom, 24)

            HStack {
                if step > 0 {
                    Button { go(to: step - 1) } label: {
                        Text("Back").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.pressable)
                    .foregroundColor(theme.text)
                    .transition(.opacity)
                }
                Spacer()
                Button(action: advance) {
                    Text(isLastStep ? "Get started" : "Next")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .crossfadeOnChange(of: isLastStep)
                        .padding(.horizontal, 28)
                        .frame(height: 48)
                        .background(Capsule().fill(Theme.selectedBlue))
                }
                .buttonStyle(.pressableSoft)
            }
        }
        .padding(32)
        .frame(maxWidth: 700, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bar.edgesIgnoringSafeArea(.all))
    }

    private var isLastStep: Bool { step == pages.count - 1 }

    private func page(_ index: Int) -> some View {
        let page = pages[index]
        return VStack(spacing: 0) {
            Image(systemName: page.symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 100, height: 100)
                .background(Circle().fill(Theme.selectedBlue))
                .accessibilityHidden(true)
                .staggeredEntrance(0)

            Text("\(index + 1) / \(pages.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.textSecondary)
                .padding(.top, 30)
                .staggeredEntrance(1)

            Text(page.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .staggeredEntrance(2)

            Text(page.detail)
                .font(.system(size: 18))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 560)
                .padding(.top, 14)
                .staggeredEntrance(3)
        }
    }

    private func advance() {
        if isLastStep {
            onFinish()
        } else {
            go(to: step + 1)
        }
    }

    /// The leaving page takes its exit direction from the last render, so a change of direction is rendered first
    /// and the page turns on the next run-loop pass.
    private func go(to target: Int) {
        let isForward = target > step
        guard isForward != forward else {
            withAnimation(Motion.layout) { step = target }
            return
        }
        forward = isForward
        DispatchQueue.main.async {
            withAnimation(Motion.layout) { step = target }
        }
    }

    private struct Page {
        let symbol: String
        let title: String
        let detail: String
    }
}

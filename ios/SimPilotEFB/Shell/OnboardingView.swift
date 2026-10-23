import SwiftUI

struct OnboardingView: View {
    @Environment(\.theme) private var theme
    let onFinish: () -> Void
    @State private var step = 0

    private let pages = [
        Page(symbol: "airplane", title: "Your flight at a glance",
             detail: "SimPilot brings route planning, maps, charts, weather and VATSIM tools to your iPad."),
        Page(symbol: "doc.text", title: "Load your SimBrief flight",
             detail: "Open Settings → SimBrief and enter your username or pilot ID. Maps, weather and VATSIM work without the simulator."),
        Page(symbol: "wifi", title: "Connect to MSFS 2024",
             detail: "Run the PC bridge and open the SimPilot Link panel in MSFS. Keep your iPad and PC on the same Wi-Fi. The app discovers the bridge automatically; enter its address in Settings if needed."),
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.selectedBlue)
                    .accessibilityHint("Close the introduction and open the app")
            }

            Spacer(minLength: 32)

            Image(systemName: pages[step].symbol)
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 100, height: 100)
                .background(Circle().fill(Theme.selectedBlue))
                .accessibilityHidden(true)

            Text("\(step + 1) / \(pages.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.textSecondary)
                .padding(.top, 30)

            Text(pages[step].title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Text(pages[step].detail)
                .font(.system(size: 18))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 560)
                .padding(.top, 14)

            Spacer(minLength: 32)

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Theme.selectedBlue : theme.separator)
                        .frame(width: index == step ? 24 : 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(pages.count)")
            .padding(.bottom, 24)

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation(.easeInOut(duration: 0.2)) { step -= 1 } }
                        .foregroundColor(theme.text)
                }
                Spacer()
                Button(action: advance) {
                    Text(step == pages.count - 1 ? "Get started" : "Next")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .frame(height: 48)
                        .background(Capsule().fill(Theme.selectedBlue))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .frame(maxWidth: 700, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bar.edgesIgnoringSafeArea(.all))
    }

    private func advance() {
        if step == pages.count - 1 {
            onFinish()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
        }
    }

    private struct Page {
        let symbol: String
        let title: String
        let detail: String
    }
}

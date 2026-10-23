import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @State private var chartNav: ChartNavigation?
    @StateObject private var updates = UpdateChecker()
    @Environment(\.openURL) private var openURL
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if let release = updates.available, !updates.dismissed {
                HStack(spacing: 16) {
                    Text("Update available: \(release.version) (\(release.build))")
                    Spacer()
                    Button("Update") {
                        guard let url = updates.installURL else {
                            app.showSettings = true
                            return
                        }
                        DiagnosticLog.record(.info, "Updates", "Opening the selected installer at the user's request")
                        openURL(url) { accepted in
                            if !accepted {
                                DiagnosticLog.record(.warning, "Updates", "Installer couldn't open; showing the manual download page")
                                openURL(AppRelease.page)
                            }
                        }
                    }
                    Button("Later") { updates.dismissed = true }
                }
                .font(.system(size: 14))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .foregroundColor(theme.text)
                .background(theme.pill)
            }
            HStack(spacing: 0) {
                if app.sidebarVisible && app.module == .map {
                    FlightFolderView()
                        .frame(width: 310)
                        .transition(.move(edge: .leading))
                }
                ZStack {
                    switch app.module {
                    case .map: EnrouteMapScreen()
                    case .charts: ChartsScreen(navigation: $chartNav)
                    case .aircraft: AircraftScreen()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            BottomToolbar(chartNav: app.module == .charts ? chartNav : nil)
        }
        .background(theme.bar.edgesIgnoringSafeArea(.all))
        .sheet(isPresented: $app.showSettings) { SettingsView().environmentObject(app).environmentObject(app.bridge).environmentObject(updates).environment(\.theme, theme) }
        .sheet(isPresented: $app.showOfp) { OfpSheet().environmentObject(app).environment(\.theme, theme) }
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView { hasCompletedOnboarding = true }
                .environment(\.theme, theme)
                .preferredColorScheme(app.night ? .dark : .light)
        }
        .task { await updates.check() }
    }
}

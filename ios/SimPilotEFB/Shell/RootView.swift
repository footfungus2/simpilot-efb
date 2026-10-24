import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var chartNav: ChartNavigation?
    @StateObject private var updates = UpdateChecker()
    @Environment(\.openURL) private var openURL
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
                .zIndex(1) // the update banner drops out from under the top bar
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
                .transition(.dropDown)
            }
            HStack(spacing: 0) {
                if app.sidebarVisible && app.module == .map {
                    FlightFolderView()
                        .frame(width: 310)
                        .transition(.slide(from: .leading))
                }
                ZStack {
                    switch app.module {
                    case .map: EnrouteMapScreen().transition(.screen)
                    case .charts: ChartsScreen(navigation: $chartNav).transition(.screen)
                    case .aircraft: AircraftScreen().transition(.screen)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            // Module switch and sidebar use the layout curve whoever triggers them (toolbar, top bar, Flight Folder).
            .animation(Motion.layout, value: app.module)
            .animation(Motion.layout, value: app.sidebarVisible)
            BottomToolbar(chartNav: app.module == .charts ? chartNav : nil)
        }
        .animation(Motion.layout, value: showsUpdateBanner)
        .background(theme.bar.edgesIgnoringSafeArea(.all))
        .sheet(isPresented: $app.showSettings) { SettingsView().environmentObject(app).environmentObject(app.bridge).environmentObject(updates).themed(theme) }
        .sheet(isPresented: $app.showOfp) { OfpSheet().environmentObject(app).themed(theme) }
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView { hasCompletedOnboarding = true }
                .themed(theme)
                .preferredColorScheme(app.preferredColorScheme)
        }
        .task { await updates.check() }
        .onAppear(perform: syncAppearance)
        .onChange(of: colorScheme) { _ in syncAppearance() }
        .onChange(of: scenePhase) { _ in syncAppearance() }
        .onChange(of: app.followSystemAppearance) { _ in syncAppearance() }
        .onChange(of: app.night) { _ in syncAppearance() }
        .onChange(of: app.accent) { _ in syncAppearance() }
    }

    private var showsUpdateBanner: Bool { updates.available != nil && !updates.dismissed }

    /// Theme → Match iPad: night follows the iPad's appearance. Skipped in the background, where iOS briefly renders
    /// both appearances for the app-switcher snapshots; coming back to the foreground catches up.
    private func syncAppearance() {
        if app.followSystemAppearance, UIApplication.shared.applicationState != .background {
            let dark = colorScheme == .dark
            if app.night != dark { app.night = dark }
        }
        WindowAppearance.apply(follow: app.followSystemAppearance, night: app.night, accent: app.accent)
    }
}

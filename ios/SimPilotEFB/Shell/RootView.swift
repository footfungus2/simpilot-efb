import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @State private var chartNav: ChartNavigation?

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
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
        .sheet(isPresented: $app.showSettings) { SettingsView().environmentObject(app).environmentObject(app.bridge).environment(\.theme, theme) }
        .sheet(isPresented: $app.showOfp) { OfpSheet().environmentObject(app).environment(\.theme, theme) }
    }
}

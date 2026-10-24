import SwiftUI

@main
struct SimPilotEFBApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.bridge)
                .themed(app.theme)
                // nil with Theme → Match iPad: the iPad's own appearance (RootView keeps `night` in step).
                .preferredColorScheme(app.preferredColorScheme)
                .onAppear {
                    DiagnosticLog.record(.info, "App", "App session started")
                    #if DEBUG
                    ChartsModel.removePlaceholderCharts(from: app.chartPack)
                    #endif
                    app.connect()
                }
        }
    }
}

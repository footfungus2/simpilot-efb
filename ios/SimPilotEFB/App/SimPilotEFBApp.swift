import SwiftUI

@main
struct SimPilotEFBApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.bridge)
                .environment(\.theme, app.theme)
                .preferredColorScheme(app.night ? .dark : .light)
                .onAppear {
                    DiagnosticLog.record(.info, "App", "App session started")
                    app.connect()
                }
        }
    }
}

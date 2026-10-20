import SwiftUI
import WebKit

/// "Documents": the SimBrief OFP rendered from its HTML.
struct OfpSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Group {
                if let html = app.ofp?.ofpHtml, !html.isEmpty {
                    HTMLView(html: wrap(html))
                } else {
                    Text("Load a SimBrief flight to see the OFP here.").foregroundColor(.secondary)
                }
            }
            .navigationTitle(app.ofp.map { "OFP \($0.callsign)" } ?? "Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentationMode.wrappedValue.dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }

    private func wrap(_ body: String) -> String {
        let bg = app.night ? "#1b1d21" : "#ffffff"
        let fg = app.night ? "#e6e6e6" : "#111111"
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{background:\(bg);color:\(fg);margin:16px} pre{font-size:13px;line-height:1.25}
        img{max-width:100%} a{color:#3d8bff}</style></head><body>\(body)</body></html>
        """
    }
}

struct HTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: URL(string: "https://www.simbrief.com/"))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML: String? }
}

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Where imported PDFs are kept and how their pages are drawn.
enum DocumentFiles {
    enum ImportError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case let .unreadable(name): return "\(name) couldn't be opened. Password-protected and damaged PDFs aren't supported."
            }
        }
    }

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ doc: ImportedDocument) -> URL { folder.appendingPathComponent("\(doc.id.uuidString).pdf") }

    /// Copies a PDF picked in Files into the app.
    static func importPDF(from source: URL) throws -> ImportedDocument {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.lastPathComponent
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0, !pdf.isLocked else { throw ImportError.unreadable(name) }
        let doc = ImportedDocument(title: source.deletingPathExtension().lastPathComponent, pageCount: pdf.pageCount)
        try FileManager.default.copyItem(at: source, to: url(doc))
        return doc
    }

    static func remove(_ doc: ImportedDocument) {
        try? FileManager.default.removeItem(at: url(doc))
        AnnotationStore.removeAll(prefix: key(doc, page: nil))
    }

    /// Key for the Pencil notes of a page (or, without a page, the prefix of all pages of the document).
    static func key(_ doc: ImportedDocument, page: Int?) -> String {
        page.map { "doc-\(doc.id.uuidString)-p\($0)" } ?? "doc-\(doc.id.uuidString)-p"
    }

    /// The page as an image (long side about 2400 px, so text stays sharp when zoomed) and its size in PDF points,
    /// which is what the Pencil notes are stored in.
    static func render(_ doc: ImportedDocument, page index: Int) async -> (image: UIImage, size: CGSize)? {
        let file = url(doc)
        return await Task.detached(priority: .userInitiated) { () -> (UIImage, CGSize)? in
            guard let pdf = PDFDocument(url: file), let page = pdf.page(at: index) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            guard size.width > 0, size.height > 0 else { return nil }
            let scale = 2400 / max(size.width, size.height)
            let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
            return (image, size)
        }.value
    }
}

/// Your own PDFs (airline procedures, airport documents, checklists) kept in the app: bookmarks, last page read
/// and Apple Pencil notes, with the same night mode and zoom as the charts. Works without the PC.
struct DocumentsPage: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @ObservedObject var store: FlightToolsStore
    var compact: Bool

    @State private var showImporter = false
    @State private var importError: String?
    @State private var opened: ImportedDocument?
    @State private var removing: ImportedDocument?

    private var documents: [ImportedDocument] { store.data.documents.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }

    var body: some View {
        VStack(spacing: 16) {
            Card(title: "Documents", accessory: {
                ActionButton(label: "Import PDF", systemImage: "square.and.arrow.down", minWidth: 0) { showImporter = true }
            }, content: {
                VStack(alignment: .leading, spacing: 10) {
                    if let importError {
                        Text(importError).font(.system(size: 13)).foregroundColor(Theme.warnOrange).fixedSize(horizontal: false, vertical: true)
                    }
                    if let ofp = app.ofp {
                        Button { app.showOfp = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "airplane.departure").font(.system(size: 22)).foregroundColor(Theme.selectedBlue).frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("SimBrief OFP · \(ofp.callsign)").font(.system(size: 16, weight: .semibold)).foregroundColor(theme.text)
                                    Text("\(ofp.origin.icao) → \(ofp.destination.icao)").font(.system(size: 13)).foregroundColor(theme.textSecondary)
                                }
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(theme.pill))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                    if documents.isEmpty {
                        Text("Import PDFs from Files: airline procedures, airport briefings, your own checklists. They stay in the app, with bookmarks and Pencil notes.")
                            .font(.system(size: 14)).foregroundColor(theme.textSecondary)
                    } else {
                        ForEach(documents) { doc in row(doc) }
                    }
                }
            })
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .fullScreenCover(item: $opened) { doc in
            DocumentViewer(store: store, documentID: doc.id)
                .environmentObject(app)
                .themed(theme)
        }
        .alert(item: $removing) { doc in
            Alert(title: Text("Remove \(doc.title)?"), message: Text("The imported copy and its Pencil notes are deleted. The original in Files stays."),
                  primaryButton: .destructive(Text("Remove")) { store.removeDocument(doc.id) }, secondaryButton: .cancel())
        }
    }

    private func row(_ doc: ImportedDocument) -> some View {
        HStack(spacing: 12) {
            Button { opened = doc } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.system(size: 22)).foregroundColor(Theme.selectedBlue).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(doc.title).font(.system(size: 16, weight: .semibold)).foregroundColor(theme.text).lineLimit(2)
                        Text("\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")"
                             + (doc.bookmarks.isEmpty ? "" : " · \(doc.bookmarks.count) bookmark\(doc.bookmarks.count == 1 ? "" : "s")")
                             + (doc.lastPage > 0 ? " · last read page \(doc.lastPage + 1)" : ""))
                            .font(.system(size: 13)).foregroundColor(theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            Button { removing = doc } label: {
                Image(systemName: "trash").font(.system(size: 15)).foregroundColor(theme.textSecondary).frame(width: 40, height: 40)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Remove \(doc.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.pill))
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case let .failure(error):
            importError = error.localizedDescription
        case let .success(urls):
            var failures: [String] = []
            for url in urls {
                do { store.data.documents.append(try DocumentFiles.importPDF(from: url)) }
                catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { importError = failures.joined(separator: "\n") }
        }
    }
}

extension ImportedDocument: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Full-screen reader: page arrows, bookmarks, the chart viewer's zoom and Pencil notes.
private struct DocumentViewer: View {
    @Environment(\.theme) private var theme
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage("invertChartsAtNight") private var invertAtNight = true
    @ObservedObject var store: FlightToolsStore
    let documentID: UUID

    @State private var page = 0
    @State private var rendered: (image: UIImage, size: CGSize, page: Int)?
    @State private var failed = false
    @State private var annotating = false
    @State private var clearToken = 0
    @State private var showBookmarks = false
    @State private var started = false

    private var doc: ImportedDocument? { store.document(documentID) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                if let doc, let rendered {
                    ZoomableChartView(image: rendered.image, dark: theme.night && invertAtNight,
                                      page: ChartPage(index: rendered.page, width: Double(rendered.size.width), height: Double(rendered.size.height), geoReferenced: false, areas: [], image: nil),
                                      ownship: nil, resetKey: DocumentFiles.key(doc, page: rendered.page),
                                      annotating: annotating, clearToken: clearToken)
                        .transition(.opacity)
                } else if failed {
                    Text("This page couldn't be drawn.").font(.system(size: 15)).foregroundColor(theme.textSecondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.night ? Color.black : Color(white: 0.92))
        }
        .background(theme.bar.edgesIgnoringSafeArea(.all))
        .onAppear {
            guard !started, let doc else { return }
            started = true
            page = min(max(doc.lastPage, 0), doc.pageCount - 1)
        }
        .task(id: page) { await load() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            RoundIconButton(systemName: "xmark") { presentationMode.wrappedValue.dismiss() }
                .accessibilityLabel("Close")
            Text(doc?.title ?? "").font(.system(size: 16, weight: .semibold)).foregroundColor(theme.text).lineLimit(1)
            Spacer(minLength: 8)
            PillGroup {
                PillIcon(systemName: "arrow.left") { go(page - 1) }.disabled(page <= 0)
                Text("\(page + 1) / \(doc?.pageCount ?? 0)").font(.system(size: 14, weight: .medium)).monospacedDigit()
                    .foregroundColor(theme.text).padding(.horizontal, 4)
                PillIcon(systemName: "arrow.right") { go(page + 1) }.disabled(page + 1 >= (doc?.pageCount ?? 0))
            }
            PillGroup {
                PillIcon(systemName: bookmarked ? "bookmark.fill" : "bookmark", selected: bookmarked) { store.toggleBookmark(documentID, page: page) }
                    .accessibilityLabel(bookmarked ? "Remove bookmark" : "Bookmark this page")
                PillIcon(systemName: "list.bullet") { showBookmarks = true }
                    .accessibilityLabel("Bookmarks")
                    .popover(isPresented: $showBookmarks) { bookmarkList }
                PillIcon(systemName: "pencil.tip", selected: annotating) { annotating.toggle() }
                    .accessibilityLabel("Annotate")
                PillIcon(systemName: "trash") { clearToken += 1 }
                    .accessibilityLabel("Clear notes on this page")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(theme.bar)
    }

    private var bookmarked: Bool { doc?.bookmarks.contains(page) ?? false }

    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bookmarks").font(.system(size: 17, weight: .semibold))
            if let marks = doc?.bookmarks, !marks.isEmpty {
                ForEach(marks, id: \.self) { mark in
                    Button("Page \(mark + 1)") { showBookmarks = false; go(mark) }
                        .font(.system(size: 16)).padding(.vertical, 4)
                }
            } else {
                Text("Tap the bookmark button to mark a page.").font(.system(size: 14)).foregroundColor(.secondary)
            }
        }
        .padding(16).frame(minWidth: 220, alignment: .leading)
        .themed(theme)
    }

    private func go(_ target: Int) {
        guard let doc, (0..<doc.pageCount).contains(target) else { return }
        page = target
    }

    private func load() async {
        guard let doc else { return }
        failed = false
        store.setLastPage(documentID, page: page)
        let shown = page
        let result = await DocumentFiles.render(doc, page: shown)
        guard shown == page else { return } // another page was picked meanwhile
        if let result { rendered = (result.image, result.size, shown) } else { failed = true }
    }
}

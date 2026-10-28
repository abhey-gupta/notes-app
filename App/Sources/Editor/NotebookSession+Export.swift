import Document
import Export
import Foundation
import InkEnginePencilKit
import InkModel

extension NotebookSession {
    /// Fraction of the progress bar spent reading pages; the exporter fills the rest.
    private nonisolated static let loadShare = 0.3

    /// Vector PDF of the selected pages in a temp directory (§9), for the share sheet; imported PDF pages
    /// keep their original page under the ink. Reads pages through
    /// the open `DocumentStore` (unflushed edits included); pages it had to load are evicted again.
    func exportPDF(
        _ selection: PageSelection,
        asShown: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let store else { throw PDFExportError.noPages }
        let manifest = await store.manifest
        let ids = manifest.notebook.pages
        let range = try selection.indices(pageCount: ids.count)
        var pages: [Page] = []
        pages.reserveCapacity(range.count)
        for (n, id) in ids[range].enumerated() {
            try Task.checkCancellation()
            let wasLoaded = await store.isLoaded(id)
            try await pages.append(store.page(id))
            if !wasLoaded {
                try? await store.evict(page: id)
            }
            progress(Self.loadShare * Double(n + 1) / Double(range.count))
        }
        let options = PDFExportOptions(notebook: manifest.notebook, exportsAsShown: asShown)
        var exporter = PDFExporter(palette: DesignSystemPDFPalette()) { asset in
            PhotoCache.decode(store.imageURL(for: asset))
        }
        // PDF imports: the ink is flattened onto the original pages (#119).
        exporter.artwork = artwork
        return try await exporter.exportPDF(pages: pages, options: options) { fraction in
            progress(Self.loadShare + (1 - Self.loadShare) * fraction)
        }
    }
}

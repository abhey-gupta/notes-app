import Canvas
import Document
import Editing
import InkModel

/// `PageResidency` as the edit pipeline's page mirror; page-order changes also re-lay out the editor
/// (`NotebookSession.refreshPages`).
@MainActor
final class ResidencyMirror: PageMirror {
    private let residency: PageResidency
    private let onPagesChanged: @MainActor () async -> Void

    init(residency: PageResidency, onPagesChanged: @escaping @MainActor () async -> Void) {
        self.residency = residency
        self.onPagesChanged = onPagesChanged
    }

    var pageIDs: [PageID] {
        residency.pageIDs
    }

    func page(_ id: PageID) -> Page? {
        residency.page(id)
    }

    func ensureLoaded(_ id: PageID) async throws(DocumentError) -> Page {
        try await residency.ensureLoaded(id)
    }

    func didApply(_ edit: PageEdit, to page: PageID) {
        residency.didApply(edit, to: page)
    }

    func reload(_ page: PageID) async {
        await residency.reload(page)
    }

    func pagesDidChange() async {
        await onPagesChanged()
    }
}

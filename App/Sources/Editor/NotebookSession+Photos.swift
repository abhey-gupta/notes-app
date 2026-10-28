import Canvas
import Document
import Foundation
import InkModel
import os

/// Photos from the toolbar flyout (#157).
///
/// ```
/// flyout tap ─▶ EditorState.insertPhoto(data) ─▶ PhotoImport.prepare (off main: orientation, ≤ 2048 px, HEIC)
///   ─▶ EditPipeline.run("photo"): store.writeImage (images/<asset>.heic, before the edit that needs it)
///   ─▶ SelectionMachine.insert: PageEdit.addImages (one undo step) ─▶ shown selected, ready to move/resize
/// ```
///
/// The photo lands on the page under the page indicator, centered in its visible part at 40 % of the page
/// width (`PhotoImport.frame`).
extension NotebookSession {
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "editor")

    func insertPhoto(_ data: Data) {
        guard let edits, let store, let residency, let selection, !isClosed else { return }
        let index = host.state.currentPage
        guard residency.pageIDs.indices.contains(index) else { return }
        let pageID = residency.pageIDs[index]
        let placement = visiblePageRect(of: pageID)
        let pageSize = residency.pageSize
        Task { @MainActor [weak self] in
            guard let prepared = await Task.detached(priority: .userInitiated) { PhotoImport.prepare(data) }.value else {
                Self.log.error("photo import: not an image (\(data.count) bytes)")
                return
            }
            guard let self, !isClosed else { return }
            let asset = ImageAssetID()
            let frame = PhotoImport.frame(pixelSize: prepared.pixelSize, visible: placement, pageSize: pageSize)
            // Bytes first, in order with the edits: the placement below reads them as soon as it lands.
            edits.run("photo") { try await store.writeImage(prepared.data, asset: asset) }
            selection.insert(PageImage(asset: asset, frame: frame), on: pageID)
            state.exitFocus()
        }
    }

    /// The part of `page` on screen between the chrome margins, page space (the whole page if it isn't
    /// visible).
    private func visiblePageRect(of page: PageID) -> CGRect {
        let viewport = host.viewport
        guard let visible = viewport.page(page) else { return CGRect(origin: .zero, size: residency?.pageSize ?? .zero) }
        let screen = CGRect(origin: .zero, size: viewport.size).inset(by: host.margins)
        return screen.applying(viewport.viewToPage(visible))
    }
}

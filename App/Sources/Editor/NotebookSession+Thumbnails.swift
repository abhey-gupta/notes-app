import Canvas
import Foundation
import InkEngine
import InkModel

/// Page thumbnails and the library cover (ARCHITECTURE.md §5.5, #33).
///
/// ```
/// commit ─▶ thumbnails.pageChanged (1 s debounce) ─▶ engine.render off main ─▶ thumbs/<page>.heic (+ cover.heic)
/// page leaves window ─▶ flush(page:)      close / background ─▶ flush()      page loads ─▶ ensure (missing only)
/// overview cell on screen ─▶ fill (missing only: page loaded, rendered, released; one at a time)
/// paper or theme change ─▶ regenerate every page, one in memory at a time
/// cover written ─▶ library.coverDidChange ─▶ "Continue" card reloads the file
/// ```
extension NotebookSession {
    func makeThumbnailService(package url: URL) -> ThumbnailService {
        let id = notebookID
        return ThumbnailService(
            package: url,
            renderer: ThumbnailService.renderer(engine),
            options: ThumbnailService.Options(
                onCoverWritten: { [weak self] in
                    Task { @MainActor in self?.library.coverDidChange(for: id) }
                },
                onPageWritten: { [weak self] page in
                    Task { @MainActor in self?.state.pages.thumbnailWritten(page) }
                }
            )
        )
    }

    /// Feeds the page's new state to the service (debounced there; the hop never blocks the edit queue).
    func thumbnailChanged(_ id: PageID) {
        guard let thumbnails, let snapshot = thumbnailSnapshot(resident: id) else { return }
        Task { await thumbnails.pageChanged(snapshot.page, isCover: snapshot.isCover) }
    }

    /// Notebooks from before thumbnails existed get theirs as their pages load (two `stat`s otherwise).
    func ensureThumbnails(_ id: PageID) {
        guard let thumbnails, let snapshot = thumbnailSnapshot(resident: id) else { return }
        Task { await thumbnails.ensure(snapshot.page, isCover: snapshot.isCover) }
    }

    /// A page left the window: its thumbnail renders now instead of after the debounce.
    func flushThumbnail(_ id: PageID) {
        guard let thumbnails else { return }
        Task { await thumbnails.flush(page: id) }
    }

    /// An overview cell came on screen: a page never loaded on the canvas has no thumbnail yet (#207).
    func wantThumbnail(_ id: PageID) {
        guard thumbnails != nil, !isClosed, !thumbnailWants.contains(id) else { return }
        thumbnailWants.append(id)
        guard thumbnailFill == nil else { return }
        thumbnailFill = Task(priority: .utility) { [weak self] in await self?.fillThumbnails() }
    }

    /// The cell scrolled away before its turn.
    func unwantThumbnail(_ id: PageID) {
        thumbnailWants.removeAll { $0 == id }
    }

    private func fillThumbnails() async {
        while let thumbnails, !Task.isCancelled, !thumbnailWants.isEmpty {
            let id = thumbnailWants.removeFirst()
            let isCover = residency?.pageIDs.first == id
            await thumbnails.fill(id, isCover: isCover) { id in try await self.loadThumbnailSnapshot(id) }
        }
        thumbnailFill = nil
    }

    /// Every thumbnail shows the paper: redo them all in the background.
    func regenerateThumbnails() {
        guard let thumbnails, let residency else { return }
        let ids = residency.pageIDs
        thumbnailRegeneration?.cancel()
        thumbnailRegeneration = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await thumbnails.regenerate(ids) { id in try await self.loadThumbnailSnapshot(id) }
        }
    }

    private func thumbnailSnapshot(resident id: PageID) -> (page: PageSnapshot, isCover: Bool)? {
        guard let residency, let page = residency.page(id) else { return nil }
        return (PageSnapshot(page: page, size: residency.pageSize), residency.pageIDs.first == id)
    }

    /// The page as its thumbnail should show it: the mirror if resident, else loaded and released again.
    private func loadThumbnailSnapshot(_ id: PageID) async throws -> PageSnapshot? {
        guard let residency, !isClosed else { return nil }
        return try await PageSnapshot(page: residency.peek(id), size: residency.pageSize)
    }
}

import Document
import Editing
import InkModel

/// Sync conflicts in the editor (#225, mock 05 C): ghost ink of a replaced version under a page's ink, and
/// Keep mine writing that version back into the page.
extension NotebookSession {
    /// Shows `ghosts` (the replaced versions' strokes by page) as ghost ink; pages left out lose theirs.
    func setGhosts(_ ghosts: [PageID: [Stroke]]) {
        for page in Set(self.ghosts.keys).union(ghosts.keys) where self.ghosts[page] != ghosts[page] {
            engine.setGhost(ghosts[page] ?? [], on: page)
        }
        self.ghosts = ghosts
    }

    /// Keep mine: `page` becomes `content` (one undo step, "Keep Mine"), checkpointed at once. Returns the
    /// page's `rev` in the package afterwards (what sync records as this version), or `nil` if the edit
    /// failed. Runs on the notebook's own pipeline (the owner's, in a split), so it sits between strokes.
    func keepMine(_ content: PageContent, on page: PageID) async -> UInt64? {
        let session = owner ?? self
        guard let edits = session.edits, let store = session.store else { return nil }
        return await withCheckedContinuation { continuation in
            var applied = false
            edits.edit("Keep Mine", on: page) { current in
                let replacing = Self.replacing(current, with: content)
                // Already the replaced version: nothing to edit, its rev is still recorded.
                applied = replacing.isEmpty
                return (replacing, ())
            } then: { _, result in
                applied = applied || result != nil
            }
            edits.run("keep mine checkpoint") {
                guard applied else { return continuation.resume(returning: nil) }
                do {
                    try await store.flush()
                    await continuation.resume(returning: store.manifest.entry(for: page)?.rev)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The edits that turn `page` into `content`: every stroke replaced, photos swapped if they differ.
    private static func replacing(_ page: Page, with content: PageContent) -> [PageEdit] {
        var edits: [PageEdit] = []
        if page.strokes != content.strokes {
            edits.append(.replace(
                old: page.strokes.enumerated().map { PlacedStroke(index: $0, stroke: $1) },
                new: content.strokes.enumerated().map { PlacedStroke(index: $0, stroke: $1) }
            ))
        }
        if page.images != content.images {
            if !page.images.isEmpty {
                edits.append(.removeImages(page.images.enumerated().map { PlacedImage(index: $0, image: $1) }))
            }
            if !content.images.isEmpty {
                edits.append(.addImages(content.images.enumerated().map { PlacedImage(index: $0, image: $1) }))
            }
        }
        return edits
    }
}

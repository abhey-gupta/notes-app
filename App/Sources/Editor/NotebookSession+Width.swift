import Canvas
import CoreGraphics
import enum DesignSystem.Tokens
import Document
import InkModel

/// Pages expanding sideways (#129): the host runs the side grab and its live preview; the session answers
/// with how far ink reaches (the inward stop) and, on release, widens the document.
///
/// ```
/// grab ─▶ host.setInkExtent (union of every page's stroke bounds, pages read and released)
/// release ─▶ EditPipeline.run("widen"):
///   residency.setPageGeometry + host.finishSideGrab (the pages take over from the preview, under a frozen frame)
///   ─▶ left grab: every inked page gets one .transform (strokes shift right with the paper), store + mirror + engine
///   ─▶ manifest: pageSize.width, leftExtension ─▶ library, thumbnails
///   ─▶ host.endWidening once the visible pages show sharp ink (or 400 ms)
/// ```
///
/// The shift is not an undo step: it rewrites every page, so the history is cleared instead (a stroke
/// undone and redone afterwards would land at its old x).
extension NotebookSession {
    /// Widest wait for the engine to draw the widened pages before the frozen frame comes off.
    private static let widenSettleTimeout: Duration = .milliseconds(400)

    /// Host hooks that don't change per notebook: colors and templates for the preview.
    func installWidening(on host: CanvasHostView, theme: PaperTheme) {
        host.templateProvider = { [weak self] id in self?.residency?.template(of: id) }
        applyPaperAppearance(theme, to: host)
    }

    /// The preview paints with the notebook's paper (`DesignSystem` tokens, like the engine's palette).
    func applyPaperAppearance(_ theme: PaperTheme, to host: CanvasHostView) {
        let style = theme.style
        host.paperAppearance = PaperAppearance(
            paper: style.paper.uiColor, line: style.templateLine.uiColor, desk: Tokens.Colors.desk.uiColor
        )
    }

    /// Union of every page's ink and photos along x (page space), reading pages not in memory and releasing them.
    func inkExtent() async -> ClosedRange<CGFloat>? {
        guard let residency else { return nil }
        var extent: ClosedRange<CGFloat>?
        for id in residency.pageIDs {
            guard !Task.isCancelled, let page = try? await residency.peek(id) else { continue }
            for bounds in page.strokes.map(\.bounds) + page.images.map(\.bounds) {
                guard !bounds.isNull, bounds.width.isFinite else { continue }
                extent = extent.map { min($0.lowerBound, bounds.minX) ... max($0.upperBound, bounds.maxX) } ?? bounds.minX ... bounds.maxX
            }
        }
        return extent
    }

    /// Widens (or narrows) every page by `change` and tells the host when the pages are drawn.
    func widenPages(_ change: PageWidthChange) {
        guard let edits else {
            host.endWidening()
            return
        }
        edits.run("widen") { [weak self] in
            guard let self, let store, let residency else { return }
            defer { settleWidening() }
            let manifest = await store.manifest
            let notebook = manifest.notebook
            let shift = change.side == .left ? change.added : 0
            let size = CGSize(width: notebook.pageSize.width + change.added, height: notebook.pageSize.height)
            let leftExtension = notebook.leftExtension + shift
            guard size.width > 0, leftExtension >= 0 else { return }
            let visible = (host.pageWindow?.visible ?? 0 ..< 0)
                .compactMap { residency.pageIDs.indices.contains($0) ? residency.pageIDs[$0] : nil }
            awaitingSharpInk = Set(visible)

            let extensions = PageExtension(left: leftExtension, right: size.width - Notebook.a4Portrait.width - leftExtension)
            // Before the pages widen, so imported artwork (#119) redraws in place on the original page.
            artworkPlacement.pageExtension = extensions
            residency.setPageGeometry(size: size, leftExtension: leftExtension)
            host.finishSideGrab(
                layout: PageLayout(pageIDs: residency.pageIDs, pageSize: size, footer: CanvasHostView.footerHeight),
                extensions: extensions
            )
            if shift != 0 {
                try await shiftInk(by: shift, store: store, residency: residency)
                state.edits.removeAll()
            }
            try await store.updateNotebook { notebook in
                notebook.pageSize = size
                notebook.leftExtension = leftExtension
            }
            await library.documentDidSave(store.manifest)
            regenerateThumbnails()
        }
    }

    /// Moves every stroke and photo right by `dx` (left paper added or taken away), page by page; pages
    /// not in memory are read, edited and evicted again.
    private func shiftInk(by dx: CGFloat, store: DocumentStore, residency: PageResidency) async throws {
        let transform = CGAffineTransform(translationX: dx, y: 0)
        for id in residency.pageIDs {
            let wasLoaded = await store.isLoaded(id)
            let page = try await store.page(id)
            if !page.strokes.isEmpty {
                let edit = try page.transformEdit(page.strokes.map(\.id), by: transform)
                try await store.apply(edit, to: id)
                residency.didApply(edit, to: id)
            }
            if !page.images.isEmpty {
                let edit = try page.transformImagesEdit(page.images.map(\.id), by: transform)
                try await store.apply(edit, to: id)
                residency.didApply(edit, to: id)
            }
            if !wasLoaded, residency.page(id) == nil {
                try? await store.evict(page: id)
            }
        }
    }

    /// Lifts the frozen frame once every visible page has drawn its ink sharp, or after the timeout.
    private func settleWidening() {
        widenSettle?.cancel()
        let timeout = Self.widenSettleTimeout
        widenSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishSettling()
        }
        if awaitingSharpInk.isEmpty {
            finishSettling()
        }
    }

    func pageShowedSharpInk(_ id: PageID) {
        guard !awaitingSharpInk.isEmpty else { return }
        awaitingSharpInk.remove(id)
        if awaitingSharpInk.isEmpty {
            finishSettling()
        }
    }

    private func finishSettling() {
        widenSettle?.cancel()
        widenSettle = nil
        awaitingSharpInk = []
        host.endWidening()
    }

    // MARK: Host

    func canvasHostDidBeginSideGrab(_ host: CanvasHostView) {
        state.dismissWidenHint()
        inkExtentLookup?.cancel()
        inkExtentLookup = Task { @MainActor [weak self] in
            guard let self else { return }
            let extent = await inkExtent()
            guard !Task.isCancelled else { return }
            host.setInkExtent(extent)
        }
    }

    func canvasHost(_: CanvasHostView, didWidenPages change: PageWidthChange) {
        inkExtentLookup?.cancel()
        widenPages(change)
    }
}

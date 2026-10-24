import InkModel

/// One eraser gesture on one page, in either mode (ARCHITECTURE.md §6): turns eraser samples into
/// `PageEdit`s.
///
/// Each batch yields an edit to apply right away (immediate feedback: `.remove` in stroke mode,
/// `.replace(old, pieces)` in partial mode). ``edit()`` is the whole gesture as one edit against the
/// starting page, equivalent to applying every batch edit in order: record that as the gesture's single
/// undo step (``EditStack/coalesceLast(_:into:)``), so undo applies one edit however long the scrub.
///
/// Value type: copy it to try a batch and keep the copy only if the edit was accepted.
public struct EraserGesture: Sendable {
    private enum Sweep {
        case stroke(StrokeEraser)
        case partial(PartialEraser)
    }

    /// Erase mode.
    public let mode: EraserSettings.Mode
    /// The page as the gesture found it.
    public let page: Page
    private var sweep: Sweep

    /// Starts a gesture over `page` with an eraser of `diameter` points.
    public init(page: Page, diameter: Float, mode: EraserSettings.Mode) {
        self.mode = mode
        self.page = page
        switch mode {
        case .stroke: sweep = .stroke(StrokeEraser(page: page, diameter: diameter))
        case .partial: sweep = .partial(PartialEraser(page: page, diameter: diameter))
        }
    }

    /// Sweeps the eraser along `samples` and returns the edit for what they erased, built against
    /// `current` (the page after every earlier batch's edit), or `nil` if they erased nothing.
    public mutating func erase(_ samples: [Sample], on current: Page) throws(PageEditError) -> PageEdit? {
        switch sweep {
        case var .stroke(eraser):
            let hits = eraser.erase(samples)
            sweep = .stroke(eraser)
            return hits.isEmpty ? nil : try current.removeEdit(hits)
        case var .partial(eraser):
            let replacements = eraser.erase(samples)
            sweep = .partial(eraser)
            return replacements.isEmpty ? nil : try current.replaceEdit(replacements)
        }
    }

    /// The gesture so far as one edit against ``page``, or `nil` if nothing was erased.
    public func edit() throws(PageEditError) -> PageEdit? {
        switch sweep {
        case let .stroke(eraser):
            eraser.erased.isEmpty ? nil : try page.removeEdit(eraser.erased)
        case let .partial(eraser):
            try eraser.gestureReplacements.isEmpty ? nil : page.replaceEdit(eraser.gestureReplacements)
        }
    }
}

/// An eraser gesture as the editor drives it, across pages (ARCHITECTURE.md §6).
///
/// Each batch's edit is applied and recorded in the stack's open "Erase" group as it happens, so the ink
/// goes at once and an undo mid-gesture takes back what is done. ``finish(in:)`` then collapses those
/// per-event steps into one edit per page, so the gesture's single undo step applies one edit per page
/// however long the scrub.
///
/// ```
/// beginGroup ─▶ erase → apply → record → accept (per batch) ─▶ finish(in:) ─▶ endGroup
/// ```
public struct EraserRun: Sendable {
    private var page: PageID?
    private var gesture: EraserGesture?
    private var proposal: EraserGesture?
    /// Per-event edits accepted (recorded) so far.
    private var recorded = 0
    /// Whole-gesture edits of the pages the eraser has left.
    private var steps: [EditStep] = []
    private var isCoalescable = true

    public init() {}

    /// Sweeps the eraser along `samples` on `pageID` (whose state is `current`) and returns the edit to
    /// apply now, or `nil`. Moving to another page starts a new per-page gesture there. Call ``accept()``
    /// once the edit is applied and recorded; otherwise the batch is forgotten (its edit never happened).
    public mutating func erase(
        _ samples: [Sample],
        on pageID: PageID,
        current: Page,
        diameter: Float,
        mode: EraserSettings.Mode
    ) throws(PageEditError) -> PageEdit? {
        if page != pageID {
            leavePage()
            page = pageID
            gesture = EraserGesture(page: current, diameter: diameter, mode: mode)
        }
        guard var next = gesture else { return nil }
        let edit: PageEdit?
        do {
            edit = try next.erase(samples, on: current)
        } catch {
            // The page moved under the eraser: start over from `current` next batch.
            leavePage()
            throw error
        }
        if edit == nil {
            gesture = next
        } else {
            proposal = next
        }
        return edit
    }

    /// The last ``erase(_:on:current:diameter:mode:)`` edit was applied and recorded.
    public mutating func accept() {
        guard let proposal else { return }
        gesture = proposal
        self.proposal = nil
        recorded += 1
    }

    /// Ends the gesture: replaces its recorded per-event steps in `stack`'s open group with one edit per
    /// page, then resets. Call before closing the group. Leaves the steps alone if the group was closed
    /// meanwhile (an undo mid-gesture) or a page's gesture edit could not be built.
    @MainActor
    public mutating func finish(in stack: EditStack) {
        leavePage()
        if isCoalescable, recorded > 0 {
            stack.coalesceLast(recorded, into: steps)
        }
        self = EraserRun()
    }

    /// Forgets the gesture without touching history (undo/redo changed the page under it).
    public mutating func reset() {
        self = EraserRun()
    }

    private mutating func leavePage() {
        if let page, let gesture {
            do {
                if let edit = try gesture.edit() {
                    steps.append(EditStep(pageID: page, edit: edit))
                }
            } catch {
                isCoalescable = false
            }
        }
        page = nil
        gesture = nil
        proposal = nil
    }
}

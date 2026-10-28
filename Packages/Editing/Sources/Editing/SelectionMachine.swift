import CoreGraphics
import InkModel
import Tools

/// What the selection machine drives on screen: the selection chrome (hull, handles, context bar) and the
/// engine's lifted-ink preview. The app's adapter is the session (overlay + engine); tests record calls.
@MainActor
public protocol SelectionDisplay: AnyObject {
    /// Outline `selection` (`nil`: hide the chrome). Also the moment to get its drag preview ready.
    func showSelection(_ selection: LassoSelection?)
    /// Draw `selection`'s strokes lifted off the page, moved by `transform`; `nil` puts them back.
    func liftSelection(_ selection: LassoSelection?, transform: CGAffineTransform)
}

/// The lasso selection's one owner (ARCHITECTURE.md §6): which strokes and images are selected, whether
/// they are being dragged or an action on them is being saved, and what the display shows.
///
/// ```
/// none ─lassoClosed─▶ resolving ─page read─▶ selected ─beginDrag─▶ dragging ─endDrag─▶ committing ─saved─▶ selected
///      ─insert(image)─▶ committing ─saved─▶ selected          └──── recolor / duplicate / delete ──────▶ committing ─saved─▶ selected /
/// none
/// clear() from any state ─▶ none
/// ```
///
/// Async results (a lasso being resolved, an action being saved) only land if nothing cleared or replaced
/// the selection meanwhile. Lifted ink stays up until its drag's edit has reached the engine, even if the
/// selection was cleared, so strokes never flash back to where they started. After every action the
/// selection is rebuilt from the saved page, so the outline always matches the ink.
@MainActor
public final class SelectionMachine {
    public enum State: Equatable {
        case none
        /// A lasso closed; its page is being read.
        case resolving
        case selected(LassoSelection)
        /// Moving (`corner == nil`) or resizing from `corner`.
        case dragging(LassoSelection, corner: LassoSelection.Corner?)
        /// An action on the selection is being saved; shown, but not draggable or actionable.
        case committing(LassoSelection)
    }

    public private(set) var state = State.none

    private let edits: EditPipeline
    private weak var display: (any SelectionDisplay)?
    /// Bumped whenever the selection is cleared or replaced: stale async results compare and drop out.
    private var generation = 0

    public init(edits: EditPipeline, display: any SelectionDisplay) {
        self.edits = edits
        self.display = display
    }

    /// The selection on screen, if any.
    public var selection: LassoSelection? {
        switch state {
        case .none, .resolving: nil
        case let .selected(selection), let .dragging(selection, _), let .committing(selection): selection
        }
    }

    // MARK: Select / clear

    /// A lasso closed on `page` (page space): strokes with ≥ 50 % of their samples inside get selected,
    /// once the page has caught up with the edits before it.
    public func lassoClosed(_ path: [CGPoint], on page: PageID) {
        clear()
        state = .resolving
        let generation = generation
        edits.read(page) { [weak self] page in
            guard let self, self.generation == generation else { return }
            show(LassoSelection(lasso: path, on: page))
        }
    }

    /// Places `image` on `page` (one undo step, #157) and selects it once the edit has landed, so it can be
    /// moved or resized at once.
    public func insert(_ image: PageImage, on page: PageID) {
        clear()
        let placeholder = LassoSelection(placing: image, on: page)
        commit("Add Photo", placeholder, showing: placeholder, lifted: false) { _, page in
            ([page.addImagesEdit([image])], placeholder)
        }
    }

    /// Drops the selection (new gesture, tool change, undo/redo, tap outside, page off screen).
    public func clear() {
        generation += 1
        switch state {
        case .none:
            return
        case .resolving:
            break
        case .dragging:
            display?.liftSelection(nil, transform: .identity)
            display?.showSelection(nil)
        case .selected, .committing:
            // A committing drag keeps its lifted ink until the edit lands (`commit`'s completion).
            display?.showSelection(nil)
        }
        state = .none
    }

    // MARK: Drag

    /// A drag wants to start (`corner == nil`: move). Refused while there's nothing to drag or an action
    /// is still being saved.
    public func beginDrag(from corner: LassoSelection.Corner?) -> Bool {
        guard case let .selected(selection) = state else { return false }
        state = .dragging(selection, corner: corner)
        display?.liftSelection(selection, transform: .identity)
        return true
    }

    /// The drag so far, page space.
    public func drag(_ transform: CGAffineTransform) {
        guard case let .dragging(selection, _) = state else { return }
        display?.liftSelection(selection, transform: transform)
    }

    /// The drag ended at `transform`: one move/resize edit (one undo step). The selection is shown at the
    /// drop point and the ink stays lifted there until the edit has reached the engine.
    public func endDrag(_ transform: CGAffineTransform) {
        guard case let .dragging(selection, corner) = state else { return }
        guard !transform.isIdentity else {
            cancelDrag()
            return
        }
        display?.liftSelection(selection, transform: transform)
        let dropped = selection.applying(transform)
        display?.showSelection(dropped)
        commit(corner == nil ? "Move" : "Resize", selection, showing: dropped, lifted: true) { selection, page in
            try (selection.transformEdits(transform, on: page), selection)
        }
    }

    /// The drag was cancelled: the ink goes back, the selection stays.
    public func cancelDrag() {
        guard case let .dragging(selection, _) = state else { return }
        state = .selected(selection)
        display?.liftSelection(nil, transform: .identity)
    }

    // MARK: Actions

    /// Recolors the selected strokes (one undo step); images keep their colors.
    public func recolor(to color: InkColor) {
        perform("Recolor") { selection, page in
            try selection.recolorEdit(to: color, on: page).map { ([$0], selection) }
        }
    }

    /// Copies the selected strokes and images 20 pt right and down (one undo step) and selects the copies.
    public func duplicate() {
        perform("Duplicate") { selection, page in
            selection.duplicateEdits(on: page).map { ($0.edits, $0.selection) }
        }
    }

    /// Deletes the selected strokes and images (one undo step) and ends the selection.
    public func delete() {
        perform("Delete") { selection, page in
            try (selection.removeEdits(on: page), nil)
        }
    }

    // MARK: Private

    private func perform(_ name: String, make: @escaping @MainActor (LassoSelection, Page) throws -> ([PageEdit], LassoSelection?)?) {
        guard case let .selected(selection) = state else { return }
        commit(name, selection, showing: selection, lifted: false, make: make)
    }

    /// Saves the edits built from `selection` through the pipeline (one undo step), then shows the selection
    /// `make` returned, rebuilt from the edited page. Nothing done (or refused)? Then the original items,
    /// re-read from the page, so the outline follows wherever the ink really is.
    private func commit(
        _ name: String,
        _ selection: LassoSelection,
        showing: LassoSelection,
        lifted: Bool,
        make: @escaping @MainActor (LassoSelection, Page) throws -> ([PageEdit], LassoSelection?)?
    ) {
        state = .committing(showing)
        let generation = generation
        edits.edit(name, on: selection.pageID, make: { page in try make(selection, page) }, then: { [weak self] next, page in
            guard let self else { return }
            let current = self.generation == generation
            if current {
                if let page, let next {
                    show(next.flatMap { LassoSelection($0.strokeIDs, images: $0.imageIDs, on: page) })
                } else {
                    reread(selection)
                }
            }
            // The edit (if any) has reached the engine: put the ink down where it landed.
            if lifted {
                display?.liftSelection(nil, transform: .identity)
            }
        })
    }

    private func reread(_ selection: LassoSelection) {
        let generation = generation
        edits.read(selection.pageID) { [weak self] page in
            guard let self, self.generation == generation else { return }
            show(LassoSelection(selection.strokeIDs, images: selection.imageIDs, on: page))
        }
    }

    private func show(_ selection: LassoSelection?) {
        state = selection.map(State.selected) ?? .none
        display?.showSelection(selection)
    }
}

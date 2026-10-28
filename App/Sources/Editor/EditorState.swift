import CoreGraphics
import DesignSystem
import Export
import Foundation
import InkModel
import Observation
import Tools

/// A lasso context-bar action (§6). Each one is a single undo step.
enum SelectionAction: Equatable {
    case recolor(InkColor)
    case duplicate
    case delete
}

/// Editor chrome state: focus mode, the undo/redo buttons and the lasso context bar. The notebook's history (`EditStack`) lives
/// here so the toolbar observes it; `NotebookSession` records into it and performs undo/redo.
@MainActor
@Observable
final class EditorState {
    private(set) var isFocused = false
    /// The notebook's "Keep exact colors" (§10): custom colors aren't remapped on Night paper.
    var keepsExactColors = false
    @ObservationIgnored var onKeepsExactColors: (Bool) -> Void = { _ in }
    /// The notebook's undo history (§6).
    let edits: EditStack
    /// Pages overview (§5.2, #32).
    let pages = PagesModel()
    @ObservationIgnored var onUndo: () -> Void = {}
    @ObservationIgnored var onRedo: () -> Void = {}
    /// Lasso selection box in screen (canvas view) space for the context bar; `nil` when there is no
    /// selection or it is being dragged.
    var selectionFrame: CGRect?
    @ObservationIgnored var onSelectionAction: (SelectionAction) -> Void = { _ in }
    /// Exports the selected pages to a temp PDF (§9); `asShown` keeps Night paper. Progress in 0...1.
    @ObservationIgnored var onExportPDF: (PageSelection, Bool, @escaping @Sendable (Double) -> Void) async throws -> URL = { _, _, _ in
        throw PDFExportError.noPages
    }

    /// The one-time "Hold a page edge to widen" caption (#129) is up.
    private(set) var showsWidenHint = false
    @ObservationIgnored private var widenHintTask: Task<Void, Never>?
    /// Where the hint's shown-once flag lives.
    static let widenHintKey = "widenHintShown"

    /// Shows the widen hint once per install, a moment after the editor settles, for a few seconds.
    func offerWidenHint(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.widenHintKey), widenHintTask == nil else { return }
        defaults.set(true, forKey: Self.widenHintKey)
        widenHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !isFocused else { return }
            showsWidenHint = true
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            showsWidenHint = false
        }
    }

    /// The user found the edge (or left): the hint goes.
    func dismissWidenHint() {
        widenHintTask?.cancel()
        widenHintTask = nil
        showsWidenHint = false
    }

    var canUndo: Bool {
        edits.canUndo
    }

    var canRedo: Bool {
        edits.canRedo
    }

    init(startsFocused: Bool = false, edits: EditStack = EditStack()) {
        isFocused = startsFocused
        self.edits = edits
    }

    func undo() {
        onUndo()
    }

    func redo() {
        onRedo()
    }

    func perform(_ action: SelectionAction) {
        onSelectionAction(action)
    }

    /// Bumped when the Pencil asks for tool options (#24); the toolbar opens the current tool's popover.
    private(set) var toolOptionsRequests = 0

    func requestToolOptions() {
        exitFocus()
        toolOptionsRequests += 1
    }

    func exportPDF(
        _ selection: PageSelection,
        _ asShown: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await onExportPDF(selection, asShown, progress)
    }

    // MARK: Focus mode (§7)

    /// Pinch-in on the toolbar or More → Focus mode. Stays until `exitFocus`: drawing, scrolling and taps don't end it.
    func enterFocus() {
        isFocused = true
    }

    /// The pill's chevron, pinch-out on the pill, or a Pencil tool-options request.
    func exitFocus() {
        isFocused = false
    }
}

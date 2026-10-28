import CoreGraphics
import DesignSystem
import Export
import Foundation
import InkModel
import Observation
import Tools
import UIKit

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

    /// Pen-ups shorter than this keep a writing session "continuous".
    static let continuityGap: Duration = .milliseconds(700)

    private let clock = ContinuousClock()
    private var isInking = false
    private var sessionStart: ContinuousClock.Instant?
    private var lastPenUp: ContinuousClock.Instant?
    private var focusTask: Task<Void, Never>?

    /// `engineDidBeginStroke`: after `Tokens.Motion.focusDelay` of continuous inking, collapse chrome.
    func strokeBegan() {
        let now = clock.now
        let continuing = sessionStart != nil && lastPenUp.map { now - $0 < Self.continuityGap } ?? false
        isInking = true
        guard !isFocused, !continuing else { return }
        sessionStart = now
        let deadline = now + Tokens.Motion.focusDelay
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.focusDeadlineReached()
        }
    }

    /// The Pencil (or inking finger) lifted.
    func strokeEnded() {
        isInking = false
        lastPenUp = clock.now
    }

    private func focusDeadlineReached() {
        let stillWriting = isInking || lastPenUp.map { clock.now - $0 < Self.continuityGap } ?? false
        sessionStart = nil
        // VoiceOver and Switch Control walk the chrome element by element: it doesn't hide itself under them (#45).
        if stillWriting, !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning {
            isFocused = true
        }
    }

    /// Menu "Focus mode" or a pinch in on the toolbar.
    func enterFocus() {
        cancelPendingFocus()
        isFocused = true
    }

    /// A scroll or zoom drops a pending auto-collapse; focus mode itself stays (#158).
    func cancelPendingFocus() {
        focusTask?.cancel()
        sessionStart = nil
    }

    /// Focus mode stays through touches, ink, scrolls (#158): only the pill's chevron (or its VoiceOver
    /// action) and a Pencil tool-options request exit.
    func exitFocus() {
        cancelPendingFocus()
        guard isFocused else { return }
        isFocused = false
    }
}

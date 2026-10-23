import DesignSystem
import Observation
import Tools

/// Editor chrome state: focus mode and the undo/redo buttons. The notebook's history (`EditStack`) lives
/// here so the toolbar observes it; `NotebookSession` records into it and performs undo/redo.
@MainActor
@Observable
final class EditorState {
    private(set) var isFocused = false
    /// The notebook's undo history (§6).
    let edits: EditStack
    @ObservationIgnored var onUndo: () -> Void = {}
    @ObservationIgnored var onRedo: () -> Void = {}

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
        if stillWriting {
            isFocused = true
        }
    }

    func enterFocus() {
        isFocused = true
    }

    /// Tap on chrome, a scroll, or the pill restores the full toolbar.
    func exitFocus() {
        focusTask?.cancel()
        sessionStart = nil
        guard isFocused else { return }
        isFocused = false
    }
}

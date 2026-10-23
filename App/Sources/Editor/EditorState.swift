import CoreGraphics
import DesignSystem
import Observation

/// Minimal editor state so the chrome is interactive. Stand-in for `Tools.ToolState` (§6); keep it
/// App-local and swap it out when the Tools work lands.
@MainActor
@Observable
final class EditorState {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, highlighter, eraser, lasso

        var id: Self {
            self
        }

        var symbol: Symbol {
            switch self {
            case .pen: .pen
            case .highlighter: .highlighter
            case .eraser: .eraser
            case .lasso: .lasso
            }
        }

        var label: String {
            rawValue.capitalized
        }

        /// Tools that put ink down (and so count toward focus mode).
        var inks: Bool {
            self == .pen || self == .highlighter
        }
    }

    /// Placeholder stroke in page-normalized coordinates (0…1 of page width), so it survives rotation.
    struct Stroke: Identifiable {
        let id: Int
        let page: Int
        let tool: Tool
        let role: InkRole
        var points: [CGPoint]
    }

    var tool: Tool = .pen
    /// Index into `Tokens.quickColors`.
    var quickColor = 0
    private(set) var isFocused = false
    private(set) var strokes: [Stroke] = []
    private var redoStack: [Stroke] = []
    private var nextID = 0

    var inkRole: InkRole {
        Tokens.quickColors[quickColor]
    }

    var canUndo: Bool {
        !strokes.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    init(startsFocused: Bool = false) {
        isFocused = startsFocused
    }

    // MARK: Strokes

    func commit(page: Int, points: [CGPoint], tool: Tool) {
        guard points.count > 1 || tool.inks else { return }
        strokes.append(Stroke(id: nextID, page: page, tool: tool, role: inkRole, points: points))
        nextID += 1
        redoStack.removeAll()
    }

    /// Stroke eraser: removes strokes on `page` passing within `radius` of `point`.
    func erase(page: Int, at point: CGPoint, radius: CGFloat) {
        let before = strokes.count
        strokes.removeAll { stroke in
            stroke.page == page && stroke.points.contains { hypot($0.x - point.x, $0.y - point.y) < radius }
        }
        if strokes.count != before {
            redoStack.removeAll()
        }
    }

    func undo() {
        guard let last = strokes.popLast() else { return }
        redoStack.append(last)
    }

    func redo() {
        guard let stroke = redoStack.popLast() else { return }
        strokes.append(stroke)
    }

    // MARK: Focus mode (§7)

    /// Pen-ups shorter than this keep a writing session "continuous".
    static let continuityGap: Duration = .milliseconds(700)

    private let clock = ContinuousClock()
    private var isInking = false
    private var sessionStart: ContinuousClock.Instant?
    private var lastPenUp: ContinuousClock.Instant?
    private var focusTask: Task<Void, Never>?

    /// Stand-in for `engineDidBeginStroke`: after `Tokens.Motion.focusDelay` of continuous inking, collapse chrome.
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

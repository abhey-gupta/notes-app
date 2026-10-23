import CoreGraphics
import DesignSystem
import InkModel
import Observation
import Tools

/// Placeholder ink + focus mode so the chrome is interactive until the canvas lands (#21). Tool choice and
/// settings live in `Tools.ToolState`.
@MainActor
@Observable
final class EditorState {
    /// Placeholder stroke in page-normalized coordinates (0…1 of page width), so it survives rotation.
    struct Stroke: Identifiable {
        let id: Int
        let page: Int
        let tool: Tool
        let color: InkColor
        /// Width in page points.
        let width: Float
        var points: [CGPoint]
    }

    private(set) var isFocused = false
    private(set) var strokes: [Stroke] = []
    private var redoStack: [Stroke] = []
    private var nextID = 0

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

    /// Commits a pen or highlighter stroke with the tool's current color and width.
    func commit(page: Int, points: [CGPoint], tools: ToolState) {
        let tool = tools.tool
        guard tool.inks, !points.isEmpty else { return }
        let width = tool == .highlighter ? tools.highlighter.width : tools.pen.width
        strokes.append(Stroke(id: nextID, page: page, tool: tool, color: tools.currentColor, width: width, points: points))
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

import Foundation
import InkModel
import Observation

/// Current tool, per-tool settings, quick colors and toolbar placement (ARCHITECTURE.md §6, §7).
///
/// One per window. Every change is saved to `UserDefaults` as a ``ToolSettings`` JSON blob, debounced by
/// ``saveDelay`` so slider drags and rapid taps write once; call ``flush()`` when the scene backgrounds.
/// Defaults (quick colors etc.) come from the caller so this package stays free of DesignSystem.
@MainActor
@Observable
public final class ToolState {
    /// `UserDefaults` key used when none is given.
    public static let defaultsKey = "toolState"

    /// Current tool.
    public var tool: Tool {
        didSet {
            if tool != oldValue {
                previousTool = oldValue
            }
            changed(tool != oldValue)
        }
    }

    /// Tool before the last switch (not persisted): Pencil "switch to previous" and eraser toggles go back to it.
    public private(set) var previousTool: Tool = .pen

    /// Pen settings.
    public var pen: PenSettings {
        didSet { changed(pen != oldValue) }
    }

    /// Highlighter settings.
    public var highlighter: HighlighterSettings {
        didSet { changed(highlighter != oldValue) }
    }

    /// Eraser settings.
    public var eraser: EraserSettings {
        didSet { changed(eraser != oldValue) }
    }

    /// Pen quick colors (1–5, ``ToolSettings/quickColorCounts``). Edit through the quick-color methods.
    public private(set) var quickColors: [InkColor] {
        didSet { changed(quickColors != oldValue) }
    }

    /// Highlighter quick colors (1–5): the toolbar shows these while the highlighter is current (#125).
    public private(set) var highlighterQuickColors: [InkColor] {
        didSet { changed(highlighterQuickColors != oldValue) }
    }

    /// Toolbar dock.
    public var dock: ToolbarDock {
        didSet { changed(dock != oldValue) }
    }

    /// Toolbar pinched to the compact pill.
    public var isCompact: Bool {
        didSet { changed(isCompact != oldValue) }
    }

    /// Debounce between the last change and the write.
    public let saveDelay: Duration

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    /// Pending debounced write; internal so tests can await it instead of racing a clock.
    @ObservationIgnored private(set) var saveTask: Task<Void, Never>?

    /// Loads persisted settings from `defaults[key]`, falling back field by field to `initial`.
    public init(
        initial: ToolSettings = ToolSettings(),
        defaults: UserDefaults = .standard,
        key: String = ToolState.defaultsKey,
        saveDelay: Duration = .milliseconds(400)
    ) {
        self.defaults = defaults
        self.key = key
        self.saveDelay = saveDelay
        let settings = defaults.data(forKey: key).map { ToolSettings.decode($0, defaults: initial) } ?? initial
        tool = settings.tool
        pen = settings.pen
        highlighter = settings.highlighter
        eraser = settings.eraser
        quickColors = settings.quickColors
        highlighterQuickColors = settings.highlighterQuickColors
        dock = settings.dock
        isCompact = settings.isCompact
    }

    /// Snapshot of everything persisted.
    public var settings: ToolSettings {
        ToolSettings(
            tool: tool,
            pen: pen,
            highlighter: highlighter,
            eraser: eraser,
            quickColors: quickColors,
            highlighterQuickColors: highlighterQuickColors,
            dock: dock,
            isCompact: isCompact
        )
    }

    // MARK: Tools

    /// Makes `tool` current. Returns `true` if it already was: the toolbar treats that as "show options" (#27).
    @discardableResult
    public func select(_ tool: Tool) -> Bool {
        let wasCurrent = self.tool == tool
        self.tool = tool
        return wasCurrent
    }

    // MARK: Pencil gestures (#24)

    /// Pencil double-tap / squeeze "switch to eraser": eraser, or back to the tool before it.
    public func toggleEraser() {
        tool = tool == .eraser ? (previousTool == .eraser ? .pen : previousTool) : .eraser
    }

    /// Pencil "switch to previous tool".
    public func switchToPrevious() {
        tool = previousTool == tool ? .pen : previousTool
    }

    /// Color of the current inking tool; the pen's color for eraser and lasso (it tints the chrome).
    public var currentColor: InkColor {
        tool == .highlighter ? highlighter.color : pen.color
    }

    // MARK: Quick colors

    /// Whose quick colors the toolbar shows and edits: the highlighter's while it is current, else the pen's.
    public var paletteTool: Tool {
        tool == .highlighter ? .highlighter : .pen
    }

    /// Quick colors of ``paletteTool``.
    public var currentQuickColors: [InkColor] {
        paletteTool == .highlighter ? highlighterQuickColors : quickColors
    }

    /// Slot whose color ``paletteTool`` currently uses, if any.
    public var activeQuickColor: Int? {
        currentQuickColors.firstIndex(of: paletteColor)
    }

    /// Quick-color tap: that tool takes the slot's color immediately; a pen slot also makes the pen current.
    public func selectQuickColor(_ index: Int) {
        guard currentQuickColors.indices.contains(index) else { return }
        let color = currentQuickColors[index]
        if paletteTool == .pen {
            tool = .pen
        }
        paletteColor = color
    }

    /// Replaces a slot (long-press, quick-colors editor). If the tool was using that slot it follows the new color.
    public func setQuickColor(_ color: InkColor, at index: Int) {
        guard currentQuickColors.indices.contains(index) else { return }
        let follows = paletteColor == currentQuickColors[index]
        currentPalette[index] = color
        if follows {
            paletteColor = color
        }
    }

    /// Appends a slot (max five). Returns its index, or `nil` when full.
    @discardableResult
    public func addQuickColor(_ color: InkColor) -> Int? {
        guard currentQuickColors.count < ToolSettings.quickColorCounts.upperBound else { return nil }
        currentPalette.append(color)
        return currentQuickColors.count - 1
    }

    /// Removes a slot; the last one stays.
    public func removeQuickColor(at index: Int) {
        guard currentQuickColors.indices.contains(index),
              currentQuickColors.count > ToolSettings.quickColorCounts.lowerBound else { return }
        currentPalette.remove(at: index)
    }

    /// Moves a slot to `destination` (its index once moved).
    public func moveQuickColor(from source: Int, to destination: Int) {
        let colors = currentQuickColors
        guard colors.indices.contains(source), colors.indices.contains(destination), source != destination else { return }
        var moved = colors
        moved.insert(moved.remove(at: source), at: destination)
        currentPalette = moved
    }

    private var currentPalette: [InkColor] {
        get { currentQuickColors }
        set {
            if paletteTool == .highlighter {
                highlighterQuickColors = newValue
            } else {
                quickColors = newValue
            }
        }
    }

    /// Color of ``paletteTool``.
    private var paletteColor: InkColor {
        get { paletteTool == .highlighter ? highlighter.color : pen.color }
        set {
            if paletteTool == .highlighter {
                highlighter.color = newValue
            } else {
                pen.color = newValue
            }
        }
    }

    // MARK: Persistence

    /// Writes pending changes now (scene going to background, tests).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func changed(_ isChange: Bool) {
        guard isChange else { return }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

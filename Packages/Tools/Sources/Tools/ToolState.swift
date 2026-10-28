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

    /// Laser pointer settings.
    public var laser: LaserSettings {
        didSet { changed(laser != oldValue) }
    }

    /// Pen quick colors (1...``ToolSettings/maxQuickColors``).
    public private(set) var quickColors: [InkColor] {
        didSet { changed(quickColors != oldValue) }
    }

    /// Highlighter quick colors (1...``ToolSettings/maxQuickColors``).
    public private(set) var highlighterColors: [InkColor] {
        didSet { changed(highlighterColors != oldValue) }
    }

    /// Toolbar dock.
    public var dock: ToolbarDock {
        didSet { changed(dock != oldValue) }
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
        laser = settings.laser
        quickColors = settings.quickColors
        highlighterColors = settings.highlighterColors
        dock = settings.dock
    }

    /// Snapshot of everything persisted.
    public var settings: ToolSettings {
        ToolSettings(
            tool: tool,
            pen: pen,
            highlighter: highlighter,
            eraser: eraser,
            laser: laser,
            quickColors: quickColors,
            highlighterColors: highlighterColors,
            dock: dock
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

    /// An eraser stroke lifted: back to the tool before the eraser if
    /// ``EraserSettings/autoDeselect`` is on (#156).
    public func finishedErasing() {
        guard tool == .eraser, eraser.autoDeselect else { return }
        toggleEraser()
    }

    /// Pencil "switch to previous tool".
    public func switchToPrevious() {
        tool = previousTool == tool ? .pen : previousTool
    }

    /// Color of the current inking tool; the pen's color for eraser and lasso (it tints the chrome).
    public var currentColor: InkColor {
        tool == .highlighter ? highlighter.color : pen.color
    }

    // MARK: Quick colors (#27, #125)

    /// Inking tool whose palette the toolbar shows: the highlighter's while it's current, else the pen's.
    public var paletteTool: Tool {
        tool == .highlighter ? .highlighter : .pen
    }

    /// The toolbar's quick colors: ``paletteTool``'s.
    public var palette: [InkColor] {
        paletteTool == .highlighter ? highlighterColors : quickColors
    }

    /// ``paletteTool``'s color.
    public var paletteColor: InkColor {
        paletteTool == .highlighter ? highlighter.color : pen.color
    }

    /// Slot whose color ``paletteTool`` currently uses, if any.
    public var activeQuickColor: Int? {
        palette.firstIndex(of: paletteColor)
    }

    /// Quick-color tap: ``paletteTool`` takes the slot's color at once and becomes the current tool.
    public func selectQuickColor(_ index: Int) {
        guard palette.indices.contains(index) else { return }
        setPaletteColor(palette[index])
        tool = paletteTool
    }

    /// Replaces a slot (swatch long-press, the colors popover). If the tool was using it, it follows.
    public func setQuickColor(_ color: InkColor, at index: Int) {
        guard palette.indices.contains(index) else { return }
        let follows = paletteColor == palette[index]
        updatePalette { $0[index] = color }
        if follows {
            setPaletteColor(color)
        }
    }

    /// Appends a slot (at most ``ToolSettings/maxQuickColors``); returns its index, or `nil` when full.
    @discardableResult
    public func addQuickColor(_ color: InkColor) -> Int? {
        guard palette.count < ToolSettings.maxQuickColors else { return nil }
        updatePalette { $0.append(color) }
        return palette.count - 1
    }

    /// Removes a slot; the last one stays.
    public func removeQuickColor(at index: Int) {
        guard palette.count > 1, palette.indices.contains(index) else { return }
        updatePalette { $0.remove(at: index) }
    }

    /// Moves a slot to `destination` (an index in the palette after the move).
    public func moveQuickColor(from source: Int, to destination: Int) {
        guard palette.indices.contains(source), palette.indices.contains(destination), source != destination else { return }
        updatePalette { $0.insert($0.remove(at: source), at: destination) }
    }

    private func updatePalette(_ change: (inout [InkColor]) -> Void) {
        if paletteTool == .highlighter {
            change(&highlighterColors)
        } else {
            change(&quickColors)
        }
    }

    private func setPaletteColor(_ color: InkColor) {
        if paletteTool == .highlighter {
            highlighter.color = color
        } else {
            pen.color = color
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

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
        didSet { changed(tool != oldValue) }
    }

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

    /// Quick-color slots (always ``ToolSettings/quickColorCount``). Change with ``setQuickColor(_:at:)``.
    public private(set) var quickColors: [InkColor] {
        didSet { changed(quickColors != oldValue) }
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
    @ObservationIgnored private var saveTask: Task<Void, Never>?

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

    /// Color of the current inking tool; the pen's color for eraser and lasso (it tints the chrome).
    public var currentColor: InkColor {
        tool == .highlighter ? highlighter.color : pen.color
    }

    // MARK: Quick colors

    /// Slot whose color the pen currently uses, if any.
    public var activeQuickColor: Int? {
        quickColors.firstIndex(of: pen.color)
    }

    /// Quick-color tap: the pen takes the slot's color immediately and becomes the current tool.
    public func selectQuickColor(_ index: Int) {
        guard quickColors.indices.contains(index) else { return }
        pen.color = quickColors[index]
        tool = .pen
    }

    /// Replaces a slot (palette long-press, #27). If the pen was using that slot it follows the new color.
    public func setQuickColor(_ color: InkColor, at index: Int) {
        guard quickColors.indices.contains(index) else { return }
        let penFollows = pen.color == quickColors[index]
        quickColors[index] = color
        if penFollows {
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

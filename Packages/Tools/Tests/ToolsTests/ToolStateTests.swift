import Foundation
import InkModel
import Testing
@testable import Tools

@MainActor
struct ToolStateTests {
    private let suite = "ToolStateTests-\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeState(_ defaults: UserDefaults, initial: ToolSettings = ToolSettings(), delay: Duration = .seconds(60)) -> ToolState {
        ToolState(initial: initial, defaults: defaults, key: "tools", saveDelay: delay)
    }

    // MARK: Persistence

    @Test func freshStateUsesInitialSettings() throws {
        let initial = ToolSettings(quickColors: [.custom(RGBA8(r: 1, g: 2, b: 3)), .primary, .semantic(.accent)])
        let state = try makeState(makeDefaults(), initial: initial)
        #expect(state.settings == initial)
        #expect(state.dock == .top && state.tool == .pen)
    }

    @Test func everySettingSurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        let state = makeState(defaults)
        state.select(.eraser)
        state.pen.kind = .brush
        state.pen.size.millimetres = 12
        state.pen.size.saved[2] = 18
        state.pen.pressure = false
        state.highlighter.size.millimetres = 3
        state.highlighter.color = .semantic(.accent)
        state.eraser.mode = .partial
        state.eraser.widthIndex = 2
        state.eraser.autoDeselect = false
        state.laser.mode = .dot
        state.setQuickColor(.custom(RGBA8(r: 0x7E, g: 0x4F, b: 0xD8)), at: 2)
        state.dock = .left
        state.flush()

        let relaunched = makeState(defaults)
        #expect(relaunched.settings == state.settings)
        #expect(relaunched.tool == .eraser && relaunched.dock == .left)
        #expect(relaunched.pen.kind == .brush && relaunched.pen.size == InkSize(12, saved: [6, 10, 18]))
        #expect(relaunched.pen.sizes[.ballpoint] == PenSettings.defaultSize(for: .ballpoint), "other families keep theirs")
        #expect(relaunched.highlighter.size.millimetres == 3)
        #expect(relaunched.eraser == EraserSettings(mode: .partial, widthIndex: 2, autoDeselect: false))
        #expect(relaunched.laser.mode == .dot)
    }

    /// Settings saved before the laser (#159) keep everything else; the laser starts in trail mode.
    @Test func settingsWithoutLaserKeepTheRest() throws {
        let defaults = try makeDefaults()
        let state = makeState(defaults)
        state.eraser.mode = .partial
        state.flush()
        let data = try #require(defaults.data(forKey: "tools"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["laser"] = nil
        try defaults.set(JSONSerialization.data(withJSONObject: json), forKey: "tools")
        let relaunched = makeState(defaults)
        #expect(relaunched.eraser.mode == .partial && relaunched.laser == LaserSettings())
    }

    @Test func savesAreDebounced() async throws {
        let defaults = try makeDefaults()
        let state = makeState(defaults, delay: .milliseconds(50))
        state.dock = .right
        let superseded = try #require(state.saveTask)
        state.dock = .bottom
        let pending = try #require(state.saveTask)
        #expect(defaults.data(forKey: "tools") == nil, "write waits for the debounce")
        #expect(superseded.isCancelled, "a newer change supersedes the pending save")

        // Await the save task rather than polling a wall-clock deadline: sibling @MainActor tests can hold the
        // main actor for seconds, so a deadline could lapse before the queued save ever ran.
        await pending.value
        // Keep `state` alive until here: its save task holds it weakly, and ARC may release it after last use.
        withExtendedLifetime(state) {}
        #expect(makeState(defaults).dock == .bottom)
    }

    @Test func unchangedAssignmentDoesNotWrite() async throws {
        let defaults = try makeDefaults()
        let state = makeState(defaults, delay: .milliseconds(10))
        state.dock = .top
        state.tool = .pen
        try await Task.sleep(for: .milliseconds(150))
        #expect(defaults.data(forKey: "tools") == nil)
    }

    @Test func corruptBlobFallsBackToInitial() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "tools")
        let initial = ToolSettings(dock: .bottom)
        #expect(makeState(defaults, initial: initial).settings == initial)
    }

    @Test func missingAndInvalidFieldsFallBackIndividually() throws {
        let defaults = try makeDefaults()
        let json = #"{"tool":"lasso","dock":"diagonal","pen":{"kind":3,"sizes":[],"color":"blue","pressure":true}}"#
        defaults.set(Data(json.utf8), forKey: "tools")
        let initial = ToolSettings(dock: .right)
        let state = makeState(defaults, initial: initial)
        #expect(state.tool == .lasso)
        #expect(state.dock == .right, "unknown dock → initial")
        #expect(state.pen.kind == .ballpoint, "highlighter is not a pen kind")
        #expect(state.pen.color == .semantic(.blue))
        #expect(state.quickColors == initial.quickColors)
    }

    // MARK: Tools

    @Test func selectReportsReselection() throws {
        let state = try makeState(makeDefaults())
        #expect(state.select(.pen), "pen is current by default")
        #expect(!state.select(.highlighter))
        #expect(state.tool == .highlighter)
        #expect(state.select(.highlighter))
    }

    @Test func pencilEraserToggleReturnsToPreviousTool() throws {
        let state = try makeState(makeDefaults())
        state.select(.highlighter)
        state.toggleEraser()
        #expect(state.tool == .eraser)
        state.toggleEraser()
        #expect(state.tool == .highlighter)
        state.select(.lasso)
        state.switchToPrevious()
        #expect(state.tool == .highlighter)
        state.switchToPrevious()
        #expect(state.tool == .lasso)
    }

    @Test func eraserToggleFromFreshEraserFallsBackToPen() throws {
        let state = try makeState(makeDefaults())
        state.tool = .eraser
        state.toggleEraser()
        #expect(state.tool == .pen)
        state.toggleEraser()
        state.toggleEraser()
        #expect(state.tool == .pen)
    }

    @Test func finishedErasingReturnsToPreviousToolUnlessOff() throws {
        let state = try makeState(makeDefaults())
        state.select(.highlighter)
        state.select(.eraser)
        state.finishedErasing()
        #expect(state.tool == .highlighter)
        state.finishedErasing()
        #expect(state.tool == .highlighter, "no-op off the eraser")

        state.eraser.autoDeselect = false
        state.select(.eraser)
        state.finishedErasing()
        #expect(state.tool == .eraser)
    }

    @Test func eraserSettingsWithoutAutoDeselectKeepModeAndSize() throws {
        let defaults = try makeDefaults()
        defaults.set(Data(#"{"eraser":{"mode":"partial","widthIndex":2}}"#.utf8), forKey: "tools")
        let state = makeState(defaults)
        #expect(state.eraser == EraserSettings(mode: .partial, widthIndex: 2, autoDeselect: true))
    }

    @Test func currentColorFollowsInkingTool() throws {
        let state = try makeState(makeDefaults())
        state.pen.color = .semantic(.red)
        #expect(state.currentColor == .semantic(.red))
        state.select(.highlighter)
        #expect(state.currentColor == HighlighterSettings.yellow)
        state.select(.eraser)
        #expect(state.currentColor == .semantic(.red))
    }

    @Test func freshInstallPenIsAFineBallpoint() {
        let pen = PenSettings()
        #expect(pen.kind == .ballpoint)
        #expect(pen.size.millimetres == 0.5)
    }

    @Test func settingsClampWidths() {
        var pen = PenSettings(kind: .highlighter, sizes: [.ballpoint: InkSize(-3, saved: [9])])
        #expect(pen.kind == .ballpoint && pen.size == InkSize(0.1, saved: [2, 0.5, 1]))
        pen.size.millimetres = 1.2345
        #expect(pen.size.millimetres == 1.2)
        pen.size.millimetres = 12
        #expect(pen.size.millimetres == 2)
        pen.kind = .brush
        #expect(pen.size.millimetres == 8, "each family has its own size")
        pen.size.millimetres = 1
        #expect(pen.size.millimetres == 6, "brush range starts at 6 mm")
        var highlighter = HighlighterSettings()
        highlighter.size.millimetres = .nan
        #expect(highlighter.size.millimetres == HighlighterSettings.sizeRange.lowerBound)
        var eraser = EraserSettings(widthIndex: 9)
        #expect(eraser.width == 32)
        eraser.widthIndex = -1
        #expect(eraser.widthIndex == 0)
        #expect(ToolSettings(quickColors: [.primary]).quickColors.count == ToolSettings.quickColorCount)
    }

    // MARK: Quick colors

    @Test func quickColorRecolorsPenImmediately() throws {
        let state = try makeState(makeDefaults())
        #expect(state.activeQuickColor == 0)
        state.selectQuickColor(1)
        #expect(state.pen.color == .semantic(.blue))
        #expect(state.activeQuickColor == 1)
        #expect(state.tool == .pen)
    }

    @Test(arguments: [Tool.highlighter, .eraser, .lasso, .laser])
    func quickColorSwitchesToPen(from tool: Tool) throws {
        let state = try makeState(makeDefaults())
        state.select(tool)
        state.selectQuickColor(2)
        #expect(state.tool == .pen && state.pen.color == .semantic(.red))
    }

    @Test func outOfRangeQuickColorIsIgnored() throws {
        let state = try makeState(makeDefaults())
        state.select(.eraser)
        state.selectQuickColor(3)
        state.setQuickColor(.semantic(.accent), at: -1)
        #expect(state.tool == .eraser && state.pen.color == .primary)
        #expect(state.quickColors == ToolSettings().quickColors)
    }

    @Test func replacingActiveSlotRecolorsPen() throws {
        let state = try makeState(makeDefaults())
        let purple = InkColor.custom(RGBA8(r: 0x7E, g: 0x4F, b: 0xD8))
        state.setQuickColor(purple, at: 0)
        #expect(state.pen.color == purple && state.activeQuickColor == 0)
        state.setQuickColor(.semantic(.accent), at: 2)
        #expect(state.pen.color == purple, "inactive slot leaves the pen alone")
    }

    @Test func customPenColorHasNoActiveSlot() throws {
        let state = try makeState(makeDefaults())
        state.pen.color = .custom(RGBA8(r: 0x1E, g: 0x8E, b: 0x6E))
        #expect(state.activeQuickColor == nil)
    }

    // MARK: Active tool

    @Test func activeToolCarriesOnlyItsOwnSettings() throws {
        let state = try makeState(makeDefaults())
        state.pen.kind = .brush
        state.pen.size.millimetres = 10
        state.pen.color = .semantic(.blue)
        let width = 10 * InkSize.pointsPerMillimetre
        #expect(state.active == .ink(.brush, color: .semantic(.blue), width: width))
        state.pen.pressure = false
        #expect(state.active == .ink(.brush, color: .semantic(.blue), width: width, pressure: false)) // #123
        state.highlighter.color = .semantic(.accent)
        state.select(.highlighter)
        #expect(state.active == .ink(.highlighter, color: .semantic(.accent), width: 5.5 * InkSize.pointsPerMillimetre))
        state.eraser.mode = .partial
        state.select(.eraser)
        #expect(state.active == .eraser(EraserSettings(mode: .partial, widthIndex: 1)))
        state.select(.lasso)
        #expect(state.active == .lasso)
        state.select(.laser)
        #expect(state.active == .laser(.trail))
        state.laser.mode = .dot
        #expect(state.active == .laser(.dot))
    }

    /// Settings of other tools, quick colors and toolbar placement don't touch the active tool, so the
    /// editor isn't re-told (and a lasso selection isn't cleared) when they change.
    @Test func otherSettingsLeaveTheActiveToolAlone() throws {
        let state = try makeState(makeDefaults())
        state.select(.eraser)
        let eraser = state.active
        state.pen.color = .semantic(.red)
        state.highlighter.size.millimetres = 3
        state.setQuickColor(.semantic(.accent), at: 1)
        state.dock = .left
        #expect(state.active == eraser)
        state.eraser.mode = .partial
        #expect(state.active != eraser, "the eraser's own mode does")
    }
}

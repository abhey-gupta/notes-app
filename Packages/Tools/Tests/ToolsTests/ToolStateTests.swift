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
        #expect(state.dock == .top && !state.isCompact && state.tool == .pen)
    }

    @Test func everySettingSurvivesRelaunch() throws {
        let defaults = try makeDefaults()
        let state = makeState(defaults)
        state.select(.eraser)
        state.pen.kind = .brush
        state.pen.widthIndex = 4
        state.pen.pressure = false
        state.highlighter.widthIndex = 0
        state.highlighter.color = .semantic(.accent)
        state.eraser.mode = .partial
        state.eraser.widthIndex = 2
        state.setQuickColor(.custom(RGBA8(r: 0x7E, g: 0x4F, b: 0xD8)), at: 2)
        state.dock = .left
        state.isCompact = true
        state.flush()

        let relaunched = makeState(defaults)
        #expect(relaunched.settings == state.settings)
        #expect(relaunched.tool == .eraser && relaunched.dock == .left && relaunched.isCompact)
        #expect(relaunched.pen == PenSettings(kind: .brush, widthIndex: 4, color: .primary, pressure: false))
        #expect(relaunched.eraser == EraserSettings(mode: .partial, widthIndex: 2))
    }

    @Test func savesAreDebounced() async throws {
        let defaults = try makeDefaults()
        let state = makeState(defaults, delay: .milliseconds(50))
        state.dock = .right
        state.dock = .bottom
        #expect(defaults.data(forKey: "tools") == nil, "write waits for the debounce")

        // Poll instead of a fixed sleep: CI shares the machine and the debounced write can be late.
        let deadline = ContinuousClock.now + .seconds(5)
        while defaults.data(forKey: "tools") == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
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
        let json = #"{"tool":"lasso","dock":"diagonal","pen":{"kind":3,"widthIndex":99,"color":"blue","pressure":true}}"#
        defaults.set(Data(json.utf8), forKey: "tools")
        let initial = ToolSettings(dock: .right, isCompact: true)
        let state = makeState(defaults, initial: initial)
        #expect(state.tool == .lasso)
        #expect(state.dock == .right, "unknown dock → initial")
        #expect(state.isCompact, "missing → initial")
        #expect(state.pen.kind == .ballpoint, "highlighter is not a pen kind")
        #expect(state.pen.widthIndex == PenSettings.widths.count - 1)
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
        #expect(pen.width == 2.5)
    }

    @Test func settingsClampWidths() {
        var pen = PenSettings(kind: .highlighter, widthIndex: -3)
        #expect(pen.kind == .ballpoint && pen.widthIndex == 0)
        pen.widthIndex = 12
        #expect(pen.width == PenSettings.widths.last)
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

    @Test(arguments: [Tool.highlighter, .eraser, .lasso])
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
}

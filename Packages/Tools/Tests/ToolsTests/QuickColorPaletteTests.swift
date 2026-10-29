import Foundation
import InkModel
import Testing
@testable import Tools

/// Per-tool quick-color palettes, 1...5 slots (#125).
@MainActor
struct QuickColorPaletteTests {
    private let suite = "QuickColorPaletteTests-\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeState(_ defaults: UserDefaults) -> ToolState {
        ToolState(initial: ToolSettings(), defaults: defaults, key: "tools", saveDelay: .seconds(60))
    }

    @Test func highlighterHasItsOwnPalette() throws {
        let state = try makeState(makeDefaults())
        let green = InkColor.custom(RGBA8(r: 0x1E, g: 0x8E, b: 0x6E))
        state.select(.highlighter)
        #expect(state.palette == [HighlighterSettings.yellow] && state.activeQuickColor == 0)
        #expect(state.addQuickColor(green) == 1)
        state.selectQuickColor(1)
        #expect(state.tool == .highlighter && state.highlighter.color == green)
        #expect(state.pen.color == .primary && state.quickColors == ToolSettings().quickColors, "pen untouched")
        state.select(.eraser)
        #expect(state.palette == state.quickColors, "other tools show the pen's")
    }

    @Test func paletteAddRemoveMove() throws {
        let state = try makeState(makeDefaults())
        let accent = InkColor.semantic(.accent)
        #expect(state.addQuickColor(accent) == 3)
        #expect(state.addQuickColor(accent) == 4)
        #expect(state.addQuickColor(accent) == nil, "five at most")
        state.moveQuickColor(from: 0, to: 4)
        #expect(state.quickColors.first == .semantic(.blue) && state.quickColors.last == .primary)
        state.moveQuickColor(from: 4, to: 9)
        #expect(state.quickColors.last == .primary, "out of range ignored")
        for _ in 0 ..< 6 {
            state.removeQuickColor(at: 0)
        }
        #expect(state.quickColors == [.primary], "the last one stays")
    }

    @Test func palettesPersist() throws {
        let defaults = try makeDefaults()
        let state = try makeState(defaults)
        state.select(.highlighter)
        state.addQuickColor(.semantic(.blue))
        state.flush()
        let reloaded = try makeState(defaults)
        #expect(reloaded.highlighterColors == [HighlighterSettings.yellow, .semantic(.blue)])
    }
}

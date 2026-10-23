import CoreGraphics
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkModel
import Testing

/// `render(page:size:scale:)` against golden PNGs (ARCHITECTURE.md §13). See ``Golden`` for the
/// tolerance and how to re-record.
@MainActor
struct SnapshotTests {
    let engine: MetalInkEngine

    init() throws {
        engine = try #require(MetalInkEngine(palette: FixturePalette()))
    }

    private func snapshot(_ page: PageSnapshot, _ name: String, size: CGSize? = nil, scale: CGFloat = 2) async throws {
        let image = try #require(await engine.render(page: page, size: size ?? page.size, scale: scale))
        try Golden.assertMatches(image, named: name)
    }

    @Test(arguments: [
        (PenKind.fountain, InkColor.primary, Float(3)),
        (.ballpoint, .semantic(.blue), 2),
        (.brush, .semantic(.red), 6),
        (.highlighter, .semantic(.accent), 14),
    ])
    func penKind(_ kind: PenKind, color: InkColor, width: Float) async throws {
        try await snapshot(Handwriting.penPage(kind, color: color, width: width), "pen-\(kind)")
    }

    @Test func highlighterDrawsBeneathInk() async throws {
        try await snapshot(Handwriting.highlighterPage, "highlighter-under-ink")
    }

    @Test func nightTheme() async throws {
        engine.setTheme(.night)
        try await snapshot(Handwriting.highlighterPage, "night-highlighter")
        try await snapshot(RenderFixtures.allPens, "night-all-pens", size: CGSize(width: 298, height: 421))
    }

    @Test func sharedFixture() async throws {
        try await snapshot(RenderFixtures.allPens, "all-pens", size: CGSize(width: 298, height: 421))
    }

    @Test(arguments: [
        ("blank", PageTemplate.blank),
        ("lined", .lined(spacing: 24)),
        ("dotted", .dotted(spacing: 20)),
        ("grid", .grid(spacing: 20)),
        ("cornell", .cornell),
    ])
    func template(_ name: String, _ template: PageTemplate) async throws {
        let page = PageSnapshot(page: Page(id: RenderFixtures.pageID(50), template: template), size: RenderFixtures.pageSize)
        // Half size at 2× = 1 px/pt: hairlines at their thinnest on-screen density.
        try await snapshot(page, "template-\(name)", size: CGSize(width: 297.5, height: 421))
    }

    @Test func templateZoomedIn() async throws {
        let page = PageSnapshot(page: Page(id: RenderFixtures.pageID(51), template: .cornell), size: CGSize(width: 200, height: 160))
        try await snapshot(page, "template-cornell-4x", scale: 4)
    }
}

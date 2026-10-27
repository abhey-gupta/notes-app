import CoreGraphics
import InkGeometry
import InkModel
import Testing

struct TemplateGeometryTests {
    private let a4 = Notebook.a4Portrait

    private func marks(_ template: PageTemplate) -> TemplateGeometry {
        TemplateGeometry(template, size: a4)
    }

    @Test func blankHasNoMarksOthersDo() {
        #expect(marks(.blank).isEmpty)
        for template: PageTemplate in [.lined(spacing: 24), .dotted(spacing: 24), .grid(spacing: 24), .cornell] {
            #expect(!marks(template).isEmpty, "\(template)")
        }
    }

    @Test func linedRulesStartAtTopAndStayOnPage() {
        let box = marks(.lined(spacing: 24)).lines.boundingBoxOfPath
        #expect(box.minY == TemplateGeometry.top)
        #expect(box.maxY < a4.height)
        #expect(box.width == a4.width)
    }

    @Test func dotsAndGridSitOnMultiplesOfTheSpacing() {
        let dots = marks(.dotted(spacing: 20)).dots.boundingBoxOfPath
        #expect(dots.minX == 20 - TemplateGeometry.dotRadius)
        #expect(dots.minY == 20 - TemplateGeometry.dotRadius)
        let grid = marks(.grid(spacing: 20)).lines.boundingBoxOfPath
        #expect(grid.minX == 0 && grid.minY == 0)
    }

    @Test func cornellIsTwoAndAHalfInchCueAndTwoInchSummary() {
        let lines = marks(.cornell).lines
        let cue = TemplateGeometry.cornellCue
        let summary = a4.height - TemplateGeometry.cornellSummary
        #expect(cue == 180 && TemplateGeometry.cornellSummary == 144)
        // The cue column line and the summary rule are on the path; nothing below the summary rule.
        #expect(lines.boundingBoxOfPath.maxY == summary)
        let column = lines.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 1)
        #expect(column.contains(CGPoint(x: cue, y: 400)))
        #expect(column.contains(CGPoint(x: 400, y: summary)))
        #expect(!column.contains(CGPoint(x: cue, y: summary + 20)))
    }

    @Test func damagedSpacingIsClamped() {
        #expect(!marks(.lined(spacing: .nan)).isEmpty)
        #expect(!marks(.dotted(spacing: 0)).isEmpty)
        #expect(!marks(.grid(spacing: -5)).isEmpty)
    }
}

/// Widened pages (#129): marks stay on the original grid, shifted with the ink.
struct TemplateGeometryExtensionTests {
    private func xs(_ path: CGPath) -> [CGFloat] {
        var out: [CGFloat] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint {
                out.append(element.pointee.points[0].x)
            }
        }
        return out
    }

    @Test func columnsFollowTheOriginalGridShiftedByTheExtension() {
        #expect(TemplateGeometry.columns(spacing: 20, width: 100, shift: 0) == [20, 40, 60, 80])
        // 7 pt added on the left: the old columns 20, 40, … now sit at 27, 47, …; 7 itself is the old 0 column.
        #expect(TemplateGeometry.columns(spacing: 20, width: 100, shift: 7) == [7, 27, 47, 67, 87])
        // A full spacing added: the old edge column shows at 20.
        #expect(TemplateGeometry.columns(spacing: 20, width: 100, shift: 20) == [20, 40, 60, 80])
        // Columns continue into paper added on the right as well.
        #expect(TemplateGeometry.columns(spacing: 20, width: 130, shift: 0) == [20, 40, 60, 80, 100, 120])
    }

    @Test func gridLinesAndCornellCueShiftWithTheInk() {
        let size = CGSize(width: 795, height: 842)
        let grid = TemplateGeometry(.grid(spacing: 20), size: size, leftExtension: 200)
        #expect(xs(grid.lines).first { $0 > 0 } == 20, "200 = 10 columns: the grid is unchanged")
        let shifted = TemplateGeometry(.grid(spacing: 20), size: size, leftExtension: 205)
        #expect(xs(shifted.lines).first { $0 > 0 } == 5, "the old 0 column now sits at 205 ≡ 5")
        let cornell = TemplateGeometry(.cornell, size: size, leftExtension: 200)
        #expect(xs(cornell.lines).contains(200 + TemplateGeometry.cornellCue), "cue column beside the original left edge")
    }
}

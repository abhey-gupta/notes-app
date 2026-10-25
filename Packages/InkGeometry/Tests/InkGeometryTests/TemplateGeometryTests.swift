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

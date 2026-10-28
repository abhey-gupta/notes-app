import CoreGraphics
import Foundation
import InkModel
import Testing
@testable import Tools

@MainActor
struct LassoSelectionTests {
    /// Horizontal ballpoint line from `x0` to `x1` at `y`, one sample per 2 pt.
    private func line(_ x0: Float, _ x1: Float, y: Float, color: InkColor = .primary) -> Stroke {
        Stroke(
            tool: .ballpoint, color: color, width: 2,
            samples: stride(from: x0, through: x1, by: 2).map { Sample(x: $0, y: y, t: 0) }
        )
    }

    private func square(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> [CGPoint] {
        [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
    }

    @Test func selectsStrokesWithAtLeastHalfTheirSamplesInside() throws {
        let inside = line(110, 190, y: 150)
        let half = line(150, 246, y: 160) // 25 of 49 samples at x < 200
        let mostlyOut = line(180, 300, y: 170)
        let outside = line(400, 500, y: 150)
        let page = Page(strokes: [inside, half, mostlyOut, outside])
        let selection = try #require(LassoSelection(lasso: square(100, 100, 200, 200), on: page))
        #expect(selection.strokeIDs == [inside.id, half.id])
        #expect(selection.pageID == page.id)
        #expect(selection.bounds.contains(CGPoint(x: 110, y: 150)) && selection.bounds.contains(CGPoint(x: 246, y: 160)))
    }

    @Test func emptyLassoOrTapSelectsNothing() {
        let page = Page(strokes: [line(110, 190, y: 150)])
        #expect(LassoSelection(lasso: square(300, 300, 400, 400), on: page) == nil)
        #expect(LassoSelection(lasso: [CGPoint(x: 150, y: 150), CGPoint(x: 151, y: 150)], on: page) == nil)
        #expect(LassoSelection(lasso: square(100, 100, 200, 200), on: Page()) == nil)
    }

    @Test func hullIsConvexAndEnclosesInkWithPadding() throws {
        let a = line(100, 200, y: 100)
        let b = line(150, 160, y: 300)
        let selection = try #require(LassoSelection([a.id, b.id], on: Page(strokes: [a, b])))
        for s in a.samples + b.samples {
            #expect(contains(selection.hull, CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))))
        }
        // Outset at least by the stroke radius + padding.
        #expect(selection.bounds.minX <= 100 - 1 - LassoSelection.padding)
        #expect(selection.bounds.maxY >= 300 + 1 + LassoSelection.padding)
        let n = selection.hull.count
        let signs = (0 ..< n).map { i in
            let (o, p, q) = (selection.hull[i], selection.hull[(i + 1) % n], selection.hull[(i + 2) % n])
            return (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) > 0
        }
        #expect(Set(signs).count == 1, "convex: every turn the same way")
    }

    @Test func convexHullDropsInteriorAndCollinearPoints() {
        let hull = LassoSelection.convexHull([
            CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10),
            CGPoint(x: 0, y: 10), CGPoint(x: 5, y: 5), CGPoint(x: 0, y: 0),
        ])
        #expect(Set(hull) == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
        #expect(LassoSelection.convexHull([CGPoint(x: 1, y: 1)]) == [CGPoint(x: 1, y: 1)])
    }

    @Test(arguments: LassoSelection.Corner.allCases)
    func resizeIsProportionalAboutTheOppositeCorner(corner: LassoSelection.Corner) throws {
        let stroke = line(100, 300, y: 200)
        let selection = try #require(LassoSelection([stroke.id], on: Page(strokes: [stroke])))
        let anchor = selection.point(of: corner.opposite)
        let start = selection.point(of: corner)
        // Drag the corner outward along the diagonal to 1.5×, plus a sideways wobble that must not skew.
        let diagonal = CGSize(width: start.x - anchor.x, height: start.y - anchor.y)
        let wobble = CGSize(width: -diagonal.height * 0.1, height: diagonal.width * 0.1)
        let t = selection.resizeTransform(
            dragging: corner,
            by: CGSize(width: diagonal.width * 0.5 + wobble.width, height: diagonal.height * 0.5 + wobble.height)
        )
        #expect(abs(t.a - 1.5) < 1e-9 && abs(t.d - 1.5) < 1e-9 && t.b == 0 && t.c == 0)
        let fixed = anchor.applying(t)
        #expect(abs(fixed.x - anchor.x) < 1e-9 && abs(fixed.y - anchor.y) < 1e-9)
        let resized = selection.applying(t)
        #expect(abs(resized.bounds.width - selection.bounds.width * 1.5) < 1e-6)
        #expect(abs(resized.bounds.height - selection.bounds.height * 1.5) < 1e-6)
    }

    @Test func resizeClampsAndNeverMirrors() throws {
        let stroke = line(100, 300, y: 200)
        let selection = try #require(LassoSelection([stroke.id], on: Page(strokes: [stroke])))
        let past = selection.resizeTransform(dragging: .bottomRight, by: CGSize(width: -1000, height: -1000))
        #expect(past.a > 0 && past.d > 0)
        let shrunk = selection.applying(past).bounds
        #expect(min(shrunk.width, shrunk.height) >= LassoSelection.minimumSide - 1e-9)
        let huge = selection.applying(selection.resizeTransform(dragging: .topLeft, by: CGSize(width: -1e7, height: -1e7))).bounds
        #expect(max(huge.width, huge.height) <= LassoSelection.maximumSide + 1e-6)
        #expect(selection.resizeTransform(dragging: .topLeft, by: CGSize(width: CGFloat.nan, height: 0)) == .identity)
    }

    @Test func moveBakesIntoSamplesAndUndoesInOneStep() throws {
        let a = line(100, 200, y: 100)
        let other = line(300, 400, y: 400)
        var page = Page(strokes: [a, other])
        let selection = try #require(LassoSelection(lasso: square(90, 90, 210, 110), on: page))
        #expect(try selection.transformEdits(.identity, on: page).isEmpty)
        let edit = try #require(try selection.transformEdits(CGAffineTransform(translationX: 30, y: -10), on: page).first)
        let before = page
        try page.apply(edit)
        #expect(page.strokes[0].samples.first?.x == 130 && page.strokes[0].samples.first?.y == 90)
        #expect(page.strokes[1] == other)
        let moved = try #require(LassoSelection(selection.strokeIDs, on: page))
        #expect(abs(moved.bounds.minX - selection.bounds.minX - 30) < 1e-3)
        try page.apply(edit.inverse())
        #expect(approximatelyEqual(page, before))
    }

    @Test func resizeScalesWidthsWithTheSelection() throws {
        let stroke = line(100, 200, y: 100)
        var page = Page(strokes: [stroke])
        let selection = try #require(LassoSelection([stroke.id], on: page))
        let t = selection.resizeTransform(
            dragging: .bottomRight,
            by: CGSize(width: selection.bounds.width, height: selection.bounds.height)
        )
        try page.apply(#require(try selection.transformEdits(t, on: page).first))
        #expect(abs(page.strokes[0].width - 4) < 1e-4, "2× resize doubles the base width")
    }

    @Test func recolorTouchesOnlyStrokesThatChange() throws {
        let red = InkColor.semantic(.red)
        let a = line(100, 200, y: 100)
        let b = line(100, 200, y: 120, color: red)
        var page = Page(strokes: [a, b])
        let selection = try #require(LassoSelection([a.id, b.id], on: page))
        let edit = try #require(try selection.recolorEdit(to: red, on: page))
        #expect(edit == .recolor([ColorChange(id: a.id, from: .primary, to: red)]))
        try page.apply(edit)
        #expect(page.strokes.allSatisfy { $0.color == red })
        #expect(try selection.recolorEdit(to: red, on: page) == nil)
    }

    @Test func deleteRemovesTheSelectionOnly() throws {
        let a = line(100, 200, y: 100)
        let b = line(100, 200, y: 300)
        let c = line(100, 200, y: 120)
        var page = Page(strokes: [a, b, c])
        let selection = try #require(LassoSelection([c.id, a.id], on: page))
        #expect(selection.strokeIDs == [a.id, c.id], "z-order")
        try page.apply(#require(selection.removeEdits(on: page).first))
        #expect(page.strokes.map(\.id) == [b.id])
        #expect(LassoSelection(selection.strokeIDs, on: page) == nil)
    }

    @Test func duplicateAddsOffsetCopiesWithFreshIDsAndGroups() throws {
        let group = UUID()
        let points = (0 ..< 51).map { _ in PointRendering(width: 3, height: 3) }
        let a = Stroke(
            tool: .brush, color: .primary, width: 4,
            samples: stride(from: Float(100), through: 200, by: 2).map { Sample(x: $0, y: 100, t: 0) },
            rendering: StrokeRendering(ink: StrokeRendering.Ink.watercolor, randomSeed: 7, points: points, renderGroupID: group)
        )
        let b = line(100, 200, y: 140)
        var page = Page(strokes: [a, b])
        let selection = try #require(LassoSelection([a.id, b.id], on: page))
        let (edits, copies) = try #require(selection.duplicateEdits(on: page))
        let edit = try #require(edits.first)
        try page.apply(edit)
        #expect(page.strokes.count == 4)
        let added = Array(page.strokes[2...])
        #expect(copies.strokeIDs == added.map(\.id))
        #expect(Set(added.map(\.id)).isDisjoint(with: [a.id, b.id]))
        #expect(added[0].samples.first?.x == 120 && added[0].samples.first?.y == 120)
        #expect(added[0].rendering?.randomSeed == 7)
        #expect(added[0].rendering?.renderGroupID != group && added[0].rendering?.renderGroupID != nil)
        #expect(added[1].color == b.color && added[1].width == b.width)
        #expect(abs(copies.bounds.minX - selection.bounds.minX - LassoSelection.duplicateOffset) < 1e-9)
        try page.apply(edit.inverse())
        #expect(page.strokes.map(\.id) == [a.id, b.id])
    }

    /// Each selection action is one edit, so one undo entry.
    @Test func eachActionIsOneUndoStep() throws {
        let a = line(100, 200, y: 100)
        var page = Page(strokes: [a])
        let stack = EditStack()
        var selection = try #require(LassoSelection([a.id], on: page))
        let original = page

        func run(_ edit: PageEdit?) throws {
            let edit = try #require(edit)
            try page.apply(edit)
            stack.record(edit, on: page.id)
        }
        try run(selection.transformEdits(CGAffineTransform(translationX: 10, y: 10), on: page).first)
        selection = try #require(LassoSelection(selection.strokeIDs, on: page))
        try run(selection.transformEdits(selection.resizeTransform(dragging: .topLeft, by: CGSize(width: -20, height: -20)), on: page)
            .first)
        try run(selection.recolorEdit(to: .semantic(.blue), on: page))
        let duplicate = try #require(selection.duplicateEdits(on: page))
        try run(duplicate.edits.first)
        try run(duplicate.selection.removeEdits(on: page).first)
        #expect(stack.undoCount == 5)
        while let entry = stack.undo() {
            for step in entry.steps {
                try page.apply(step.edit)
            }
        }
        #expect(approximatelyEqual(page, original))
    }

    private func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let (a, b) = (polygon[i], polygon[j])
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: Images (#157)

    private func photo(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 100, _ h: CGFloat = 60) -> PageImage {
        PageImage(asset: ImageAssetID(), frame: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func lassoSelectsImagesByCenterAlongsideStrokes() throws {
        let inside = photo(120, 120, 50, 50) // center (145, 145)
        let edge = photo(180, 180, 100, 100) // center (230, 230): out
        let ink = line(110, 190, y: 150)
        let page = Page(strokes: [ink], images: [inside, edge])
        let selection = try #require(LassoSelection(lasso: square(100, 100, 200, 200), on: page))
        #expect(selection.strokeIDs == [ink.id])
        #expect(selection.imageIDs == [inside.id])
        #expect(selection.hasInk)
        #expect(selection.bounds.contains(CGRect(x: 120, y: 120, width: 50, height: 50)))
    }

    @Test func imageOnlySelectionHasHullAroundTheFrame() throws {
        let image = photo(100, 200, 300, 150)
        let page = Page(images: [image])
        let selection = try #require(LassoSelection([], images: [image.id], on: page))
        #expect(!selection.hasInk)
        #expect(selection.imageIDs == [image.id])
        let expected = image.frame.insetBy(dx: -LassoSelection.padding, dy: -LassoSelection.padding)
        #expect(abs(selection.bounds.minX - expected.minX) < 0.01 && abs(selection.bounds.maxY - expected.maxY) < 0.01)
        #expect(LassoSelection(placing: image, on: page.id).bounds == selection.bounds)
        #expect(try selection.recolorEdit(to: .semantic(.blue), on: page) == nil)
    }

    @Test func mixedSelectionActionsMakeOneEditPerKind() throws {
        let ink = line(100, 200, y: 100)
        let image = photo(100, 120)
        var page = Page(strokes: [ink], images: [image])
        let selection = try #require(LassoSelection([ink.id], images: [image.id], on: page))

        let moves = try selection.transformEdits(CGAffineTransform(translationX: 10, y: 20), on: page)
        #expect(moves.count == 2)
        for edit in moves {
            try page.apply(edit)
        }
        #expect(page.images[0].frame.origin == CGPoint(x: 110, y: 140))
        #expect(page.strokes[0].samples[0].y == 120)

        let moved = try #require(LassoSelection(selection.strokeIDs, images: selection.imageIDs, on: page))
        let (copies, copySelection) = try #require(moved.duplicateEdits(on: page))
        #expect(copies.count == 2)
        for edit in copies {
            try page.apply(edit)
        }
        #expect(page.images.count == 2 && page.images[1].asset == image.asset && page.images[1].id != image.id)
        #expect(page.images[1].frame.origin == CGPoint(x: 130, y: 160))
        #expect(copySelection.imageIDs == [page.images[1].id] && copySelection.strokeIDs == [page.strokes[1].id])

        let removes = try copySelection.removeEdits(on: page)
        #expect(removes.count == 2)
        for edit in removes {
            try page.apply(edit)
        }
        #expect(page.images.map(\.id) == [image.id] && page.strokes.map(\.id) == [ink.id])
        #expect(LassoSelection(copySelection.strokeIDs, images: copySelection.imageIDs, on: page) == nil)
    }
}

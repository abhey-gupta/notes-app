import CoreGraphics
import Foundation
import InkModel
import Testing

func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

struct ColorTests {
    @Test func rgbaHex() throws {
        let c = try #require(RGBA8(hex: "#2C4FD6"))
        #expect(c == RGBA8(r: 0x2C, g: 0x4F, b: 0xD6, a: 0xFF))
        #expect(c.hex == "#2C4FD6FF")
        #expect(RGBA8(hex: "00000080") == RGBA8(r: 0, g: 0, b: 0, a: 0x80))
        #expect(RGBA8(rgba: 0x0102_0304).hex == "#01020304")
        #expect(RGBA8(hex: "#12345") == nil)
        #expect(RGBA8(hex: "#GGGGGG") == nil)
    }

    @Test(arguments: [InkColor.primary, .semantic(.accent), .semantic(.red), .custom(RGBA8(r: 1, g: 2, b: 3, a: 4))])
    func inkColorCodable(color: InkColor) throws {
        #expect(try roundTrip(color) == color)
    }

    @Test func inkColorEncodingIsCompact() throws {
        let data = try JSONEncoder().encode([InkColor.semantic(.blue), .custom(RGBA8(r: 255, g: 0, b: 0))])
        #expect(String(bytes: data, encoding: .utf8) == ##"["blue","#FF0000FF"]"##)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(InkColor.self, from: Data(#""teal""#.utf8)) }
    }
}

struct StrokeTests {
    let samples = [Sample(x: 10, y: 20), Sample(x: 30, y: 5, t: 0.1), Sample(x: 15, y: 40, t: 0.2)]

    @Test func sampleIsCompact() {
        #expect(MemoryLayout<Sample>.stride == 24)
    }

    @Test func boundsAreConservative() {
        let stroke = Stroke(tool: .fountain, color: .primary, width: 4, samples: samples)
        let pad = CGFloat(4 * Stroke.maxWidthScale / 2 * Float(2).squareRoot() + Stroke.boundsMargin)
        #expect(stroke.bounds == CGRect(x: 10 - pad, y: 5 - pad, width: 20 + 2 * pad, height: 35 + 2 * pad))
        #expect(Stroke(tool: .brush, color: .primary, width: 4, samples: []).bounds.isNull)
    }

    @Test func transformBakesSamplesAndScalesWidth() {
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: samples)
        let t = CGAffineTransform(translationX: 5, y: -5).scaledBy(x: 2, y: 2)
        let moved = stroke.transformed(by: t)
        #expect(moved.id == stroke.id)
        #expect(moved.samples[1].x == 65 && moved.samples[1].y == 5)
        #expect(moved.width == 4)
        #expect(moved.bounds == Stroke.bounds(of: moved.samples, width: 4))
        let rotated = stroke.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        #expect(abs(rotated.samples[0].azimuth - .pi / 2) < 1e-6)
        #expect(abs(rotated.width - 2) < 1e-6)
    }

    @Test func recolorAndCodable() throws {
        let stroke = Stroke(tool: .highlighter, color: .primary, width: 8, samples: samples)
        let blue = stroke.recolored(.semantic(.blue))
        #expect(blue.color == .semantic(.blue) && blue.id == stroke.id && blue.samples == stroke.samples)
        let decoded = try roundTrip(stroke)
        #expect(decoded == stroke)
        #expect(decoded.bounds == stroke.bounds)
    }
}

struct NotebookTests {
    @Test func markModifiedBumpsRev() throws {
        let created = Date(timeIntervalSince1970: 1000)
        var nb = Notebook(title: "Thermodynamics", cover: .navy, paper: .lined, theme: .cream, createdAt: created)
        #expect(nb.modifiedAt == created && nb.rev == 0 && nb.pageSize == Notebook.a4Portrait)
        nb.markModified(at: Date(timeIntervalSince1970: 2000))
        #expect(nb.rev == 1 && nb.modifiedAt == Date(timeIntervalSince1970: 2000))
        nb.pages = [PageID(), PageID()]
        #expect(try roundTrip(nb) == nb)
    }

    @Test func enums() throws {
        #expect(PaperTheme.night.isDark && !PaperTheme.cream.isDark)
        #expect(PaperStyle.allCases.map(\.defaultTemplate) == [
            .blank, .lined(spacing: 24), .dotted(spacing: 20), .grid(spacing: 20), .cornell,
        ])
        #expect(CoverColor.allCases.count == 8)
        #expect(PenKind.allCases.map(\.rawValue) == [0, 1, 2, 3])
        #expect(SemanticInk.allCases.map(\.rawValue) == [0, 1, 2, 3])
        let page = Page(template: .grid(spacing: 20), strokes: [Stroke(tool: .brush, color: .primary, width: 3, samples: [])])
        #expect(try roundTrip(page) == page)
    }
}

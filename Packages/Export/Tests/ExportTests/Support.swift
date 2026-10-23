import CoreGraphics
import Export
import Foundation
import InkModel

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Token values from ARCHITECTURE.md §10, inlined for tests (the app adapts `DesignSystem` instead).
/// Template lines are opaque here so tests can find them.
struct TestPalette: PDFPalette {
    func paper(_ theme: PaperTheme) -> CGColor {
        switch theme {
        case .white: srgb(0xFFFFFF)
        case .cream: srgb(0xF6F0E1)
        case .night: srgb(0x1B1C1F)
        }
    }

    func templateLine(_ theme: PaperTheme) -> CGColor {
        theme.isDark ? srgb(0x808080) : srgb(0x000000)
    }

    func ink(_ color: InkColor, on theme: PaperTheme, keepsExactColors: Bool) -> CGColor {
        switch color {
        case let .semantic(slot):
            switch slot {
            case .primary: srgb(theme.isDark ? 0xE9E8E4 : 0x1E2129)
            case .blue: srgb(theme.isDark ? 0x5FD3C4 : 0x2C4FD6)
            case .red: srgb(theme.isDark ? 0xFF8FB1 : 0xD2402F)
            case .accent: srgb(theme.isDark ? 0xFFC764 : 0xE0A400)
            }
        case let .custom(c):
            CGColor(
                srgbRed: CGFloat(c.r) / 255,
                green: CGFloat(c.g) / 255,
                blue: CGFloat(c.b) / 255,
                alpha: CGFloat(c.a) / 255
            )
        }
    }
}

enum Fixtures {
    static let yellow = InkColor.custom(RGBA8(r: 255, g: 214, b: 51))

    static func line(
        from a: CGPoint,
        to b: CGPoint,
        tool: PenKind = .ballpoint,
        color: InkColor = .primary,
        width: Float = 4
    ) -> Stroke {
        let n = 40
        let samples = (0 ..< n).map { i in
            let u = CGFloat(i) / CGFloat(n - 1)
            return Sample(x: Float(a.x + (b.x - a.x) * u), y: Float(a.y + (b.y - a.y) * u), t: Float(i) / 240)
        }
        return Stroke(tool: tool, color: color, width: width, samples: samples)
    }

    /// Handwriting-like stroke: 40–80 samples at 240 Hz, ~130 pt/s, curvature drifting smoothly (loops
    /// down to ~3.7 pt radius, like cursive letters), pressure drifting, pen widths from the §6 presets.
    /// Highlighter strokes run nearly straight, like marking a line of text.
    static func handwriting(_ rng: inout SplitMix64, tool: PenKind, color: InkColor = .primary) -> Stroke {
        let isHighlighter = tool == .highlighter
        let n = Int.random(in: 40 ... 80, using: &rng)
        var x = Float.random(in: 40 ... 520, using: &rng)
        var y = Float.random(in: 40 ... 780, using: &rng)
        var heading = isHighlighter ? 0 : Float.random(in: 0 ..< 2 * .pi, using: &rng)
        var turn = isHighlighter ? 0 : Float.random(in: -0.1 ... 0.1, using: &rng) // rad per sample
        let maxTurn: Float = isHighlighter ? 0.005 : 0.15
        var force = Float.random(in: 0.2 ... 0.9, using: &rng)
        var samples: [Sample] = []
        samples.reserveCapacity(n)
        for i in 0 ..< n {
            samples.append(Sample(x: x, y: y, force: force, t: Float(i) / 240))
            turn = min(max(turn + Float.random(in: -0.03 ... 0.03, using: &rng), -maxTurn), maxTurn)
            heading += turn
            x += 0.55 * cos(heading)
            y += 0.55 * sin(heading)
            force = min(max(force + Float.random(in: -0.03 ... 0.03, using: &rng), 0), 1)
        }
        let width: Float = isHighlighter ? 14 : [1.5, 2.5, 2.5, 4].randomElement(using: &rng) ?? 2.5
        return Stroke(tool: tool, color: tool == .highlighter ? yellow : color, width: width, samples: samples)
    }

    static let penColors: [InkColor] = [.primary, .primary, .semantic(.blue), .semantic(.red), .custom(RGBA8(r: 30, g: 142, b: 110))]

    /// A dense page: `strokes` strokes, mostly fountain/ballpoint, ~5 % highlighter, ~5 % brush. Pen color
    /// switches every ~20 strokes (people write in runs of one color).
    static func densePage(_ rng: inout SplitMix64, strokes: Int, template: PageTemplate = .lined(spacing: 24)) -> Page {
        var color = InkColor.primary
        let list = (0 ..< strokes).map { _ in
            if Int.random(in: 0 ..< 20, using: &rng) == 0 {
                color = penColors.randomElement(using: &rng) ?? .primary
            }
            let tool: PenKind = switch Int.random(in: 0 ..< 20, using: &rng) {
            case 0: .highlighter
            case 1: .brush
            case 2 ..< 11: .fountain
            default: .ballpoint
            }
            return handwriting(&rng, tool: tool, color: color)
        }
        return Page(template: template, strokes: list)
    }
}

/// Parsed export, with helpers to inspect pages.
struct PDF {
    let document: CGPDFDocument

    init(_ data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.document = document
    }

    var pageCount: Int {
        document.numberOfPages
    }

    /// 0-based page.
    func page(_ index: Int) throws -> CGPDFPage {
        guard let page = document.page(at: index + 1) else { throw CocoaError(.fileReadCorruptFile) }
        return page
    }

    /// Whether the page's resource dictionary has a sub-dictionary named `key` (`"Font"`, `"XObject"`).
    func pageHasResource(_ index: Int, _ key: String) throws -> Bool {
        guard let dict = try page(index).dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return false }
        var sub: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(resources, key, &sub)
    }

    /// Counts of content-stream operators: text (`BT`), fills (`f`, `f*`), strokes (`S`), images (`Do`).
    func operatorCounts(_ index: Int) throws -> OperatorCounts {
        final class Counts {
            var text = 0
            var fills = 0
            var strokes = 0
            var images = 0
        }
        guard let table = CGPDFOperatorTableCreate() else { return OperatorCounts() }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            info.map { Unmanaged<Counts>.fromOpaque($0).takeUnretainedValue().text += 1 }
        }
        CGPDFOperatorTableSetCallback(table, "f") { _, info in
            info.map { Unmanaged<Counts>.fromOpaque($0).takeUnretainedValue().fills += 1 }
        }
        CGPDFOperatorTableSetCallback(table, "f*") { _, info in
            info.map { Unmanaged<Counts>.fromOpaque($0).takeUnretainedValue().fills += 1 }
        }
        CGPDFOperatorTableSetCallback(table, "S") { _, info in
            info.map { Unmanaged<Counts>.fromOpaque($0).takeUnretainedValue().strokes += 1 }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { _, info in
            info.map { Unmanaged<Counts>.fromOpaque($0).takeUnretainedValue().images += 1 }
        }
        let counts = Counts()
        let stream = try CGPDFContentStreamCreateWithPage(page(index))
        let scanner = withExtendedLifetime(counts) {
            CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counts).toOpaque())
        }
        withExtendedLifetime(counts) {
            _ = CGPDFScannerScan(scanner)
        }
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return OperatorCounts(text: counts.text, fills: counts.fills, strokes: counts.strokes, images: counts.images)
    }

    /// Renders a page at 1 px/pt into sRGB RGBA8.
    func bitmap(_ index: Int) throws -> Bitmap {
        let page = try page(index)
        let box = page.getBoxRect(.mediaBox)
        var bitmap = Bitmap(width: Int(box.width), height: Int(box.height))
        try bitmap.draw { context in
            context.drawPDFPage(page)
        }
        return bitmap
    }
}

/// Content-stream operator counts.
struct OperatorCounts {
    var text = 0
    var fills = 0
    var strokes = 0
    var images = 0
}

/// One sRGB pixel (alpha dropped).
struct Pixel: Equatable, CustomStringConvertible {
    var r: Int
    var g: Int
    var b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    var description: String {
        "(\(r), \(g), \(b))"
    }
}

/// RGBA8 sRGB pixels, row 0 at the top (page space).
struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func draw(_ body: (CGContext) -> Void) throws {
        let (w, h) = (width, height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { throw CocoaError(.coderInvalidValue) }
            body(context)
        }
    }

    /// Pixel at page-space point (x right, y down).
    subscript(x: Int, y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    /// Darkest luma in a rect (for thin anti-aliased lines).
    func minLuma(x: ClosedRange<Int>, y: ClosedRange<Int>) -> Int {
        var best = 255
        for yy in y {
            for xx in x {
                let p = self[xx, yy]
                best = min(best, (p.r * 299 + p.g * 587 + p.b * 114) / 1000)
            }
        }
        return best
    }
}

/// Solid-color image rasterizer that records what it was asked to draw.
final class RecordingRasterizer: BrushRasterizer, @unchecked Sendable {
    // Unchecked: `requests` is guarded by `lock`.
    private let lock = NSLock()
    private var requests: [BrushRasterRequest] = []
    let returnsImage: Bool

    init(returnsImage: Bool) {
        self.returnsImage = returnsImage
    }

    var recorded: [BrushRasterRequest] {
        lock.withLock { requests }
    }

    func rasterize(_ request: BrushRasterRequest) async throws -> CGImage? {
        lock.withLock { requests.append(request) }
        guard returnsImage else { return nil }
        let w = Int(request.pageSize.width * request.scale)
        let h = Int(request.pageSize.height * request.scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Paint the top-left quarter red (page space), to check orientation.
        context.setFillColor(srgb(0xFF0000))
        context.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        return context.makeImage()
    }
}

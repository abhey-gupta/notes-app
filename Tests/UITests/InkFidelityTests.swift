import XCTest

/// Ink looks the same wherever it is drawn from (#71): live on the PencilKit canvas, rebuilt from the
/// document, as an inactive page's raster after scrolling, and after leaving and reopening the notebook.
/// Also: pen widths look like pens, and a pinch over the canvas zooms the page (not just the ink).
///
/// Screenshots go to the test's attachments and, if `INK_SHOTS_DIR` is set in the runner
/// (`TEST_RUNNER_INK_SHOTS_DIR=… xcodebuild test`), to PNG files there.
final class InkFidelityTests: XCTestCase {
    /// Pens drawn as horizontal lines at these window heights (normalized), highlighter last.
    private static let lines: [(name: String, y: CGFloat)] = [
        ("fountain", 0.22), ("ballpoint", 0.29), ("brush", 0.36), ("highlighter", 0.43),
    ]
    private static let x0: CGFloat = 0.3
    private static let x1: CGFloat = 0.65
    /// Window region holding the ink (normalized), away from the chrome.
    private static let inkRegion = CGRect(x: 0.2, y: 0.16, width: 0.6, height: 0.34)

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func canvas(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews["canvas"]
    }

    @MainActor
    private func open(_ app: XCUIApplication, strokes: String? = nil) {
        let cover = app.buttons["cover-Thermodynamics"]
        XCTAssertTrue(cover.waitForExistence(timeout: 20))
        cover.tap()
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 10))
        if let strokes {
            let predicate = NSPredicate(format: "value == %@", strokes)
            let loaded = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: canvas(app))], timeout: 10)
            XCTAssertEqual(loaded, .completed, "page 1 loads with \(strokes)")
        }
        settle()
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    @MainActor
    private func drawLine(_ app: XCUIApplication, y: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: Self.x0, dy: y))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: Self.x1, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        settle(2.5)
        let show = app.buttons["Show toolbar"]
        if show.exists {
            show.tap()
            settle(0.5)
        }
    }

    /// One-finger drag of `dy` window points (positive scrolls content up), without momentum.
    @MainActor
    private func scroll(_ app: XCUIApplication, by dy: CGFloat) {
        let window = app.windows.firstMatch
        let height = window.frame.height
        var remaining = dy
        while abs(remaining) > 1 {
            let step = max(min(remaining, height * 0.6), -height * 0.6)
            let from = 0.5 + step / height / 2
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: from))
            let end = start.withOffset(CGVector(dx: 0, dy: -step))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
            remaining -= step
        }
        settle()
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) -> Gray {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["INK_SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(filePath: dir).appending(path: "\(name).png"))
        }
        return Gray(screenshot.image)
    }

    /// Records a measurement (attachment, and `notes.txt` in `INK_SHOTS_DIR`).
    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "ink"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["INK_SHOTS_DIR"] else { return }
        let url = URL(filePath: dir).appending(path: "notes.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Draws each pen (relaunching to switch family: no picker yet), then the highlighter, in one app.
    @MainActor
    private func drawAllPens() -> XCUIApplication {
        var app = launch([
            "-resetLibrary", "YES", "-seedNotebooks", "1", "-resetToolState", "YES", "-allowFingerDrawing", "YES",
            "-penKind", "fountain",
        ])
        open(app, strokes: "0 strokes")
        drawLine(app, y: Self.lines[0].y)
        for (i, kind) in ["ballpoint", "brush"].enumerated() {
            app.terminate()
            app = launch(["-allowFingerDrawing", "YES", "-penKind", kind])
            open(app, strokes: "\(i + 1) stroke\(i == 0 ? "" : "s")")
            drawLine(app, y: Self.lines[i + 1].y)
        }
        app.buttons["Highlighter"].tap()
        drawLine(app, y: Self.lines[3].y)
        return app
    }

    /// Pens look like pens: line thickness in page points at the fitted zoom.
    private func checkPenWidths(_ drawn: Gray) {
        let zoom = drawn.pageZoom()
        XCTAssertGreaterThan(zoom, 1, "page fitted wider than A4 points")
        for line in Self.lines {
            let threshold: UInt8 = line.name == "highlighter" ? 245 : 160
            let thickness = drawn.thickness(from: Self.x0, to: Self.x1, nearY: line.y, threshold: threshold) / drawn.scale / zoom
            note("\(line.name) thickness \(String(format: "%.2f", thickness)) pt (zoom \(String(format: "%.3f", zoom)))")
            // Fountain: a horizontal line is the nib's thin side. Brush is PencilKit's watercolor wash.
            let expected: ClosedRange<CGFloat> = switch line.name {
            case "fountain": 0.4 ... 4
            case "ballpoint": 0.8 ... 4
            case "brush": 4 ... 30 // default watercolor 20 PK (was 25)
            default: 8 ... 30
            }
            XCTAssertTrue(expected.contains(thickness), "\(line.name) \(thickness) pt, expected \(expected)")
        }
    }

    @MainActor
    func testInkMatchesActiveInactiveAndReopenedAndPensLookLikePens() {
        var app = drawAllPens()
        let drawn = shot(app, "1-drawn")
        checkPenWidths(drawn)

        // Reopen without finger drawing (so one finger scrolls): everything rebuilt from the document.
        app.terminate()
        app = launch([])
        open(app, strokes: "4 strokes")
        drawn.expectSameInk(as: shot(app, "2-reopened"), in: Self.inkRegion, "reopened vs drawn", note: note)

        // Scroll page 1 out (page 2 takes the canvas), then back until page 1's ink shows again, a little
        // above where it was drawn (the fixed bar's inset, #191, keeps it inside `inkRegion`): page 1 is
        // now an inactive raster.
        let window = app.windows.firstMatch.frame
        scroll(app, by: window.height * 1.05)
        scroll(app, by: -window.height * 1.02)
        settle(1)
        let inactive = shot(app, "3-inactive-after-scroll")
        let shift = drawn.verticalShift(to: inactive, in: Self.inkRegion)
        note("inactive screenshot shifted \(shift) px")
        drawn.expectSameInk(as: inactive, in: Self.inkRegion, shiftedBy: shift, "inactive raster vs drawn", note: note)

        // Back to the top: page 1 takes the canvas again.
        scroll(app, by: -window.height * 2)
        settle(1)
        drawn.expectSameInk(as: shot(app, "4-scrolled-back"), in: Self.inkRegion, "scrolled back vs drawn", note: note)

        // Leave and reopen.
        app.buttons["Library"].tap()
        open(app, strokes: "4 strokes")
        let again = shot(app, "5-left-and-reopened")
        drawn.expectSameInk(as: again, in: Self.inkRegion, "left and reopened vs drawn", note: note)

        // A pinch over the ink zooms the page with it: the dot grid and the highlighter grow alike.
        canvas(app).pinch(withScale: 2, velocity: 2)
        settle(2)
        let pinched = shot(app, "6-pinched")
        let page = pinched.dotSpacing() / max(again.dotSpacing(), 1)
        let ink = pinched.yellowBandHeight() / max(again.yellowBandHeight(), 1)
        note("pinch: dot spacing ×\(String(format: "%.3f", page)), highlighter height ×\(String(format: "%.3f", ink))")
        XCTAssertGreaterThan(page, 1.2, "pinch zooms the page")
        XCTAssertEqual(ink, page, accuracy: 0.08 * page, "ink zooms with its page")
    }
}

/// Grayscale pixels of a screenshot (0 = black), for ink comparisons.
struct Gray {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    /// Pixels per window point.
    let scale: CGFloat

    init(_ image: UIImage) {
        let cg = image.cgImage
        width = cg?.width ?? 0
        height = cg?.height ?? 0
        scale = image.scale
        var bytes = [UInt8](repeating: 255, count: width * height)
        if let cg {
            let (w, h) = (width, height)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
                context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        pixels = bytes
        yellowPerRow = Self.yellowPerRow(cg)
    }

    /// Highlighter-yellow pixels in each row.
    let yellowPerRow: [Int]

    private static func yellowPerRow(_ cg: CGImage?) -> [Int] {
        guard let cg else { return [] }
        let (w, h) = (cg.width, cg.height)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (0 ..< h).map { y in
            (0 ..< w).reduce(0) { count, x in
                let i = (y * w + x) * 4
                let (r, b) = (Int(rgba[i]), Int(rgba[i + 2]))
                return count + (r > 200 && r - b > 80 ? 1 : 0)
            }
        }
    }

    /// Height (px) of the tallest band of rows crossed by highlighter yellow.
    func yellowBandHeight() -> CGFloat {
        var best = 0, run = 0
        for count in yellowPerRow {
            run = count > 30 ? run + 1 : 0
            best = max(best, run)
        }
        return CGFloat(best)
    }

    /// Distance (px) between template dots: median gap along the row (60–95 % down) with the most dots.
    func dotSpacing() -> CGFloat {
        func isDot(_ v: UInt8) -> Bool {
            (150 ... 232).contains(v) // darker than the desk (~234), lighter than ink
        }
        // Rows over paper (mostly pure white), not the desk between pages.
        let rows = (Int(0.6 * CGFloat(height)) ..< Int(0.95 * CGFloat(height))).filter { y in
            (0 ..< width).count { self[$0, y] >= 250 } > width / 2
        }
        guard let y = rows.max(by: { a, b in
            (0 ..< width).count { isDot(self[$0, a]) } < (0 ..< width).count { isDot(self[$0, b]) }
        }) else { return 0 }
        var centers: [Int] = []
        var start: Int?
        for x in 0 ... width {
            let dot = x < width && isDot(self[x, y])
            if dot, start == nil {
                start = x
            } else if !dot, let s = start {
                centers.append((s + x - 1) / 2)
                start = nil
            }
        }
        let gaps = zip(centers, centers.dropFirst()).map { $1 - $0 }.filter { $0 > 8 }.sorted()
        return gaps.isEmpty ? 0 : CGFloat(gaps[gaps.count / 2])
    }

    subscript(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 255 }
        return pixels[y * width + x]
    }

    private func rect(_ normalized: CGRect) -> (x: Range<Int>, y: Range<Int>) {
        let x0 = Int(normalized.minX * CGFloat(width)), x1 = Int(normalized.maxX * CGFloat(width))
        let y0 = Int(normalized.minY * CGFloat(height)), y1 = Int(normalized.maxY * CGFloat(height))
        return (x0 ..< x1, y0 ..< y1)
    }

    /// Pixels darker than `threshold` in `region` (normalized): ink on paper.
    func darkPixelCount(in region: CGRect, threshold: UInt8 = 96) -> Int {
        let (xs, ys) = rect(region)
        var count = 0
        for y in ys {
            for x in xs where self[x, y] < threshold {
                count += 1
            }
        }
        return count
    }

    /// Paper is pure white; the desk around it is not. Width of the white run through the row at 12 %.
    func pageWidth() -> CGFloat {
        let y = Int(CGFloat(height) * 0.12)
        let whites = (0 ..< width).filter { self[$0, y] >= 254 }
        guard let first = whites.first, let last = whites.last else { return 0 }
        return CGFloat(last - first + 1)
    }

    /// Fitted zoom (screen points per page point) from the paper width (A4: 595 pt).
    func pageZoom() -> CGFloat {
        pageWidth() / scale / 595
    }

    /// Height (px) of a horizontal line near row `nearY` (normalized) between `x0` and `x1`: median over
    /// 15 columns of the run of pixels darker than `threshold` (the median ignores template dots).
    func thickness(from x0: CGFloat, to x1: CGFloat, nearY: CGFloat, threshold: UInt8) -> CGFloat {
        let center = Int(nearY * CGFloat(height))
        let window = Int(0.03 * CGFloat(height))
        let runs = (0 ..< 15).map { i -> Int in
            let x = Int((x0 + (x1 - x0) * (0.1 + 0.8 * CGFloat(i) / 14)) * CGFloat(width))
            let inked = (center - window ... center + window).filter { self[x, $0] < threshold }
            guard let first = inked.first, let last = inked.last else { return 0 }
            return last - first + 1
        }
        return CGFloat(runs.sorted()[runs.count / 2])
    }

    /// Row-darkness correlation: how many px `other`'s ink sits below ours.
    func verticalShift(to other: Gray, in region: CGRect) -> Int {
        let r = rect(region)
        func profile(_ g: Gray) -> [Double] {
            (0 ..< g.height).map { y in r.x.reduce(0.0) { $0 + Double(255 - g[$1, y]) } }
        }
        let a = profile(self), b = profile(other)
        var best = (shift: 0, score: -Double.infinity)
        for shift in -height / 2 ... height / 2 {
            var score = 0.0
            for y in r.y where y + shift >= 0 && y + shift < height {
                score += a[y] * b[y + shift]
            }
            if score > best.score {
                best = (shift, score)
            }
        }
        return best.shift
    }

    /// Same ink in `region`: total darkness within 4 %, and at most 1 % of inked pixels differing by
    /// more than a quarter of the gray range (antialiasing differences only).
    func expectSameInk(
        as other: Gray, in region: CGRect, shiftedBy shift: Int = 0, _ label: String, note: (String) -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = rect(region)
        var darkA = 0.0, darkB = 0.0, inked = 0, differing = 0
        for y in r.y where y + shift >= 0 && y + shift < other.height {
            for x in r.x {
                let a = Int(self[x, y]), b = Int(other[x, y + shift])
                darkA += Double(255 - a)
                darkB += Double(255 - b)
                if a < 235 || b < 235 {
                    inked += 1
                    if abs(a - b) > 64 {
                        differing += 1
                    }
                }
            }
        }
        let massRatio = darkB / max(darkA, 1)
        let differingFraction = Double(differing) / Double(max(inked, 1))
        note("\(label): darkness ratio \(String(format: "%.4f", massRatio)), differing \(differing)/\(inked)")
        XCTAssertGreaterThan(inked, 2000, "\(label): ink present", file: file, line: line)
        XCTAssertEqual(massRatio, 1, accuracy: 0.04, "\(label): same ink weight", file: file, line: line)
        XCTAssertLessThan(differingFraction, 0.01, "\(label): same ink pixels", file: file, line: line)
    }
}

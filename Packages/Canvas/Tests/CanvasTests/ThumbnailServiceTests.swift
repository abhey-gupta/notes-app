#if canImport(UIKit)
    @testable import Canvas
    import CoreGraphics
    import FixtureGen
    import Foundation
    import ImageIO
    import InkEngine
    import InkEnginePencilKit
    import InkEngineTestSupport
    import InkModel
    import Testing

    /// Serialized: the debounce test is timing-sensitive and parallel renders contend for the simulator.
    @Suite(.serialized)
    struct ThumbnailServiceTests {
        /// A service over a fresh temp package and the real PencilKit engine.
        @MainActor
        private func makeService(
            debounce: Duration = .seconds(1), theme: PaperTheme = .white, onCover: (@Sendable () -> Void)? = nil
        ) -> ThumbnailService {
            let engine = PencilKitInkEngine(palette: FixturePalette())
            engine.setTheme(theme)
            let renderer = ThumbnailService.renderer(engine)
            let package = FileManager.default.temporaryDirectory.appending(path: "thumb-\(UUID().uuidString).nb")
            return ThumbnailService(
                package: package,
                renderer: { page, size, scale in
                    #expect(!ThumbnailService.isMainThread(), "thumbnail renders are requested off main")
                    return await renderer(page, size, scale)
                },
                options: ThumbnailService.Options(debounce: debounce, onCoverWritten: onCover)
            )
        }

        @Test func ensureWritesPageThumbAndCoverAsHEIC() async throws {
            let service = await makeService()
            let page = RenderFixtures.allPens
            await service.ensure(page, isCover: true)
            await service.flush()
            #expect(await service.renderCount == 1)

            let thumb = try HEIC(service.thumbnailURL(for: page.id))
            #expect(thumb.type == "public.heic")
            #expect((thumb.image.width, thumb.image.height) == (352, 456))
            let thumbPixels = RGBAPixels(thumb.image)
            #expect(thumbPixels[177, 20].isPaper, "paper above the first rule")
            #expect(thumbPixels.hasInk(near: 177, 95), "ballpoint line at page (300, 160)")

            let cover = try HEIC(service.coverURL)
            #expect((cover.image.width, cover.image.height) == (688, 392))
            let coverPixels = RGBAPixels(cover.image)
            #expect(coverPixels[372, 20].isPaper)
            #expect(coverPixels.hasInk(near: 372, 184), "same line through the cover crop")
        }

        @Test func ensureSkipsExistingFiles() async {
            let service = await makeService()
            let page = RenderFixtures.allPens
            await service.ensure(page, isCover: false)
            await service.flush()
            await service.ensure(page, isCover: false)
            await service.flush()
            #expect(await service.renderCount == 1)
            await service.ensure(page, isCover: true)
            await service.flush()
            #expect(await service.renderCount == 2, "the missing cover is rendered")
        }

        /// Pages overview (#207): a page that never loaded is loaded and rendered only if its thumb is missing.
        @Test func fillLoadsOnlyMissingThumbnails() async throws {
            let service = await makeService()
            let page = RenderFixtures.allPens
            let loads = Counter()
            let load: @Sendable (PageID) async throws -> PageSnapshot? = { id in
                #expect(id == page.id)
                loads.increment()
                return page
            }
            await service.fill(page.id, isCover: false, load: load)
            #expect(await service.renderCount == 1)
            #expect(loads.value == 1)
            let thumb = try HEIC(service.thumbnailURL(for: page.id))
            #expect(RGBAPixels(thumb.image).hasInk(near: 177, 95), "the loaded page's ink")

            await service.fill(page.id, isCover: false, load: load)
            #expect(loads.value == 1, "existing thumb: page not loaded again")
            #expect(await service.renderCount == 1)
        }

        @Test func debounceCoalescesEdits() async throws {
            let service = await makeService(debounce: .milliseconds(150))
            var page = RenderFixtures.blank.page
            for i in 1 ... 5 {
                let line = RenderFixtures.line(UInt8(i), from: CGPoint(x: 50, y: 50 * i), to: CGPoint(x: 400, y: 50 * i))
                try page.apply(page.addEdit([line]))
                await service.pageChanged(PageSnapshot(page: page, size: RenderFixtures.pageSize), isCover: false)
                try await Task.sleep(for: .milliseconds(40))
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await service.renderCount == 0, "still inside the debounce")
            try await Task.sleep(for: .milliseconds(400))
            await service.flush()
            #expect(await service.renderCount == 1)
            let pixels = try RGBAPixels(HEIC(service.thumbnailURL(for: page.id)).image)
            #expect(pixels.hasInk(near: 130, 148), "rendered the latest snapshot (5th line at y 250)")
        }

        @Test func flushRendersWithoutWaiting() async {
            let covers = Counter()
            let service = await makeService(debounce: .seconds(30), onCover: { covers.increment() })
            let page = RenderFixtures.allPens
            await service.pageChanged(page, isCover: true)
            let start = ContinuousClock.now
            await service.flush()
            #expect(ContinuousClock.now - start < .seconds(20), "well inside the 30 s debounce")
            #expect(await service.renderCount == 1)
            #expect(FileManager.default.fileExists(atPath: service.coverURL.path(percentEncoded: false)))
            #expect(covers.value == 1)
            await service.flush()
            #expect(await service.renderCount == 1, "nothing left to flush")
        }

        @Test func flushPageRendersOnlyThatPage() async {
            let service = await makeService(debounce: .seconds(30))
            let a = RenderFixtures.allPens
            let b = RenderFixtures.blank
            await service.pageChanged(a, isCover: false)
            await service.pageChanged(b, isCover: false)
            await service.flush(page: b.id)
            #expect(await service.renderCount == 1)
            #expect(FileManager.default.fileExists(atPath: service.thumbnailURL(for: b.id).path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: service.thumbnailURL(for: a.id).path(percentEncoded: false)))
        }

        @Test func olderSnapshotDoesNotReplaceNewer() async throws {
            let service = await makeService(debounce: .seconds(30))
            let newer = RenderFixtures.allPens.page.with(rev: 10)
            let older = RenderFixtures.blank.page.with(id: newer.id, rev: 3)
            await service.pageChanged(PageSnapshot(page: newer, size: RenderFixtures.pageSize), isCover: false)
            await service.pageChanged(PageSnapshot(page: older, size: RenderFixtures.pageSize), isCover: false)
            await service.flush()
            let pixels = try RGBAPixels(HEIC(service.thumbnailURL(for: newer.id)).image)
            #expect(pixels.hasInk(near: 177, 95))
        }

        @Test func nightThemePaper() async throws {
            let service = await makeService(theme: .night)
            await service.ensure(RenderFixtures.blank, isCover: true)
            await service.flush()
            let pixels = try RGBAPixels(HEIC(service.coverURL).image)
            let p = pixels[10, 10]
            #expect(p.r < 40 && p.g < 40 && p.b < 40, "night paper, got \(p)")
        }

        @Test func regenerateRendersEveryPageInOrder() async {
            let service = await makeService()
            let generator = FixtureGenerator(FixtureSpec(pages: 3, strokesPerPage: 40))
            let ids = generator.notebook.pages
            let elapsed = await service.regenerate(ids) { id in
                guard let i = ids.firstIndex(of: id) else { return nil }
                return PageSnapshot(page: generator.page(at: i), size: Notebook.a4Portrait)
            }
            #expect(elapsed > .zero)
            #expect(await service.renderCount == 3)
            for id in ids {
                #expect(FileManager.default.fileExists(atPath: service.thumbnailURL(for: id).path(percentEncoded: false)))
            }
            #expect(FileManager.default.fileExists(atPath: service.coverURL.path(percentEncoded: false)))
        }

        /// Full regeneration of a fixture notebook (§5.5 budget: 300 pages < 10 s on device). Set
        /// `THUMB_PERF_PAGES` to run; FixtureGen is slow in Debug, so generation is timed separately.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["THUMB_PERF_PAGES"] != nil))
        func fullRegenerationPerf() async {
            let pages = Int(ProcessInfo.processInfo.environment["THUMB_PERF_PAGES"] ?? "") ?? 300
            let service = await makeService()
            let generator = FixtureGenerator(FixtureSpec(pages: pages))
            let generating = ContinuousClock.now
            let snapshots = (0 ..< pages).map { PageSnapshot(page: generator.page(at: $0), size: Notebook.a4Portrait) }
            let generated = ContinuousClock.now - generating
            let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
            let elapsed = await service.regenerate(snapshots.map(\.id)) { byID[$0] }
            #expect(await service.renderCount == pages)
            let strokes = snapshots.reduce(0) { $0 + $1.strokes.count }
            Issue.record("THUMB_PERF: \(pages) pages, \(strokes) strokes: regenerate \(elapsed) (fixture generation \(generated))")
        }
    }

    /// A decoded HEIC file.
    private struct HEIC {
        let type: String
        let image: CGImage

        init(_ url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
            }
            self.type = type as String
            self.image = image
        }
    }

    /// Thread-safe call counter.
    private final class Counter: @unchecked Sendable {
        // Guarded by `lock`.
        private var count = 0
        private let lock = NSLock()

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    /// Redraws a `CGImage` into 8-bit sRGB RGBA for pixel checks.
    private struct RGBAPixels {
        let width: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            self.bytes = bytes
        }

        /// Pixel at `(x, y)`, origin top-left.
        subscript(x: Int, y: Int) -> RGBA8 {
            let i = (y * width + x) * 4
            return RGBA8(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
        }

        /// Dark ink within 3 px of `(x, y)` (thin lines land on a pixel boundary at thumbnail scale).
        func hasInk(near x: Int, _ y: Int) -> Bool {
            (y - 3 ... y + 3).contains { dy in (x - 3 ... x + 3).contains { dx in self[dx, dy].isInk } }
        }
    }

    private extension RGBA8 {
        /// White paper, allowing HEIC's lossy noise.
        var isPaper: Bool {
            r > 240 && g > 240 && b > 240
        }

        /// Ink: clearly darker than paper (thin lines are gray at thumbnail scale).
        var isInk: Bool {
            r < 200 && g < 200 && b < 200
        }
    }

    private extension Page {
        func with(id: PageID? = nil, rev: UInt64) -> Page {
            Page(id: id ?? self.id, template: template, strokes: strokes, rev: rev)
        }
    }
#endif

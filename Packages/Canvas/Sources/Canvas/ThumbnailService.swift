#if canImport(UIKit)
    import CoreGraphics
    import Document
    import Foundation
    import ImageIO
    import InkEngine
    import InkModel
    import os
    import Perf
    import UniformTypeIdentifiers

    /// Keeps `thumbs/<pageID>.heic` and `thumbs/cover.heic` on disk and fresh (ARCHITECTURE.md §5.5).
    ///
    /// Edits arrive as snapshots (``pageChanged(_:isCover:)``); a page is rendered ``Options/debounce``
    /// after its last edit, at once on ``flush(page:)`` (page leave) and ``flush()`` (close, background).
    /// ``ensure(_:isCover:)`` renders only what is missing (notebooks from before thumbnails existed);
    /// ``regenerate(_:load:)`` redoes a whole notebook (paper or theme change).
    ///
    /// Rendering goes through the injected ``Renderer`` (the engine's `render(page:size:scale:)`, which
    /// draws off main); cropping, HEIC encoding and the atomic write run on a detached task, one page at a
    /// time, so the actor stays responsive and the canvas keeps its frame budget. Nothing here runs on the
    /// main thread (asserted in debug). Each render is a `thumb.render` signpost.
    public actor ThumbnailService {
        /// Renders a page (paper + template + ink) at `size` points × `scale`; `nil` when it can't.
        public typealias Renderer = @Sendable (PageSnapshot, CGSize, CGFloat) async -> CGImage?

        /// Tuning and hooks.
        public struct Options: Sendable {
            /// Idle time after a page's last edit before it is rendered. Default 1 s.
            public var debounce: Duration
            /// Pixels per point. Default 2 (`@2x`).
            public var scale: CGFloat
            /// HEIC lossy quality, 0...1.
            public var quality: Double
            /// Called (off main) after `cover.heic` was written.
            public var onCoverWritten: (@Sendable () -> Void)?

            /// Creates options.
            public init(
                debounce: Duration = .seconds(1), scale: CGFloat = 2, quality: Double = 0.8, onCoverWritten: (@Sendable () -> Void)? = nil
            ) {
                self.debounce = debounce
                self.scale = scale
                self.quality = quality
                self.onCoverWritten = onCoverWritten
            }
        }

        /// Page thumbnail, points (§4.2: 176×228).
        public static let pageSize = CGSize(width: 176, height: 228)
        /// Cover, points (§4.2: 344×196), the library "Continue" card.
        public static let coverSize = CGSize(width: 344, height: 196)
        /// The cover shows the top of page 1 from this page point, 500 page points wide (same framing as
        /// the library's paper placeholder, so the thumbnail lands on it without a jump).
        public static let coverOrigin = CGPoint(x: 30, y: 26)
        public static let coverWidth: CGFloat = 500

        /// `thumbs/` of the package.
        public nonisolated let directory: URL

        private let renderer: Renderer
        private let options: Options
        /// Latest snapshot per edited page, waiting for its debounce or its turn.
        private var pending: [PageID: Job] = [:]
        private var lastEdit: [PageID: ContinuousClock.Instant] = [:]
        private var timers: [PageID: Task<Void, Never>] = [:]
        /// Pages whose debounce elapsed (or that were flushed), render order.
        private var queue: [PageID] = []
        private var worker: Task<Void, Never>?
        /// Renders completed so far (tests, debug HUD).
        public private(set) var renderCount = 0

        private struct Job: Sendable {
            var snapshot: PageSnapshot
            var isCover: Bool
        }

        private static let log = Logger(subsystem: "com.abhey.notespace", category: "thumb")

        /// Creates the service for the package at `package`, rendering through `renderer`.
        public init(package: URL, renderer: @escaping Renderer, options: Options = Options()) {
            directory = NotebookPackage.thumbnailsDirectory(in: package)
            self.renderer = renderer
            self.options = options
        }

        deinit {
            for timer in timers.values {
                timer.cancel()
            }
        }

        /// `thumbs/<id>.heic`.
        public nonisolated func thumbnailURL(for id: PageID) -> URL {
            directory.appending(path: "\(id).heic", directoryHint: .notDirectory)
        }

        /// `thumbs/cover.heic`.
        public nonisolated var coverURL: URL {
            directory.appending(path: "cover.heic", directoryHint: .notDirectory)
        }

        // MARK: Requests

        /// The page was edited: render it after the debounce (also the cover if `isCover`). An older
        /// snapshot (lower `rev`) than the one waiting is ignored.
        public func pageChanged(_ snapshot: PageSnapshot, isCover: Bool) {
            if let waiting = pending[snapshot.id], waiting.snapshot.rev > snapshot.rev {
                return
            }
            pending[snapshot.id] = Job(snapshot: snapshot, isCover: isCover)
            lastEdit[snapshot.id] = .now
            guard timers[snapshot.id] == nil else { return }
            timers[snapshot.id] = Task { [weak self, debounce = options.debounce] in
                var deadline = ContinuousClock.now + debounce
                while true {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled, let self, let later = await debounceDue(snapshot.id) else { return }
                    deadline = later
                }
            }
        }

        /// Renders what is missing for the page: its thumbnail, and the cover if `isCover`. Cheap when
        /// both exist (two `stat`s).
        public func ensure(_ snapshot: PageSnapshot, isCover: Bool) {
            guard pending[snapshot.id] == nil else { return }
            let fm = FileManager.default
            let missing = !fm.fileExists(atPath: thumbnailURL(for: snapshot.id).path(percentEncoded: false))
                || (isCover && !fm.fileExists(atPath: coverURL.path(percentEncoded: false)))
            guard missing else { return }
            pending[snapshot.id] = Job(snapshot: snapshot, isCover: isCover)
            enqueue(snapshot.id)
        }

        /// Renders `id` now if an edit is waiting (page scrolled out of the window).
        public func flush(page id: PageID) async {
            guard pending[id] != nil else { return }
            enqueue(id)
            await worker?.value
        }

        /// Renders every page with a waiting edit now (editor closed, app backgrounded).
        public func flush() async {
            for id in pending.keys where !queue.contains(id) {
                enqueue(id)
            }
            await worker?.value
        }

        /// Re-renders `pages` in order (the first is the cover), loading each through `load` just before
        /// its render so only one page is in memory at a time; a page `load` returns `nil` for is skipped.
        /// Returns the elapsed time. Runs alongside the debounced queue, not through it.
        @discardableResult
        public func regenerate(_ pages: [PageID], load: @Sendable (PageID) async throws -> PageSnapshot?) async -> Duration {
            let start = ContinuousClock.now
            for (i, id) in pages.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    guard let snapshot = try await load(id) else { continue }
                    await render(Job(snapshot: snapshot, isCover: i == 0))
                } catch {
                    Self.log.error("regenerate: load of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            return ContinuousClock.now - start
        }

        // MARK: Scheduling

        /// Renders if the debounce elapsed since the page's last edit (returns `nil`); otherwise the new
        /// deadline.
        private func debounceDue(_ id: PageID) -> ContinuousClock.Instant? {
            guard let last = lastEdit[id] else {
                timers[id] = nil
                return nil
            }
            let deadline = last + options.debounce
            if ContinuousClock.now < deadline {
                return deadline
            }
            timers[id] = nil
            lastEdit[id] = nil
            if pending[id] != nil {
                enqueue(id)
            }
            return nil
        }

        private func enqueue(_ id: PageID) {
            if !queue.contains(id) {
                queue.append(id)
            }
            guard worker == nil else { return }
            worker = Task { await drain() }
        }

        /// One page at a time, in queue order; a page edited again while rendering is re-queued by its timer.
        private func drain() async {
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard let job = pending.removeValue(forKey: id) else { continue }
                await render(job)
            }
            worker = nil
        }

        // MARK: Rendering

        private func render(_ job: Job) async {
            let interval = Signpost.thumbRender.begin()
            defer { interval.end() }
            let page = job.snapshot
            let scale = options.scale
            // Cover pages render once at cover scale; the page thumb is a downsample of the same raster.
            let frame = job.isCover ? Self.coverFrame(pageSize: page.size) : Self.pageFrame(pageSize: page.size)
            guard let image = await renderer(page, frame.renderSize, scale) else {
                Self.log.error("render of \(page.id, privacy: .public) produced no image")
                return
            }
            let (thumbURL, coverURL, quality) = (thumbnailURL(for: page.id), coverURL, options.quality)
            let written: Bool = await Task.detached(priority: .utility) {
                assert(!ThumbnailService.isMainThread(), "thumbnail encoding on main")
                do {
                    if job.isCover {
                        let cover = try Self.crop(image, to: frame.crop(scale))
                        try Self.writeHEIC(cover, to: coverURL, quality: quality)
                        let pageFrame = Self.pageFrame(pageSize: page.size)
                        let thumb = try Self.resample(image, to: pageFrame.renderSize, scale: scale, crop: pageFrame.crop(scale))
                        try Self.writeHEIC(thumb, to: thumbURL, quality: quality)
                    } else {
                        try Self.writeHEIC(Self.crop(image, to: frame.crop(scale)), to: thumbURL, quality: quality)
                    }
                    return true
                } catch {
                    Self.log.error("thumbnail of \(page.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }.value
            guard written else { return }
            renderCount += 1
            if job.isCover {
                options.onCoverWritten?()
            }
        }

        /// How a page maps onto a thumbnail: the page is rendered whole at `renderSize` (uniform scale), then
        /// `crop(scale)` (pixels) is cut out.
        struct Frame: Sendable {
            var renderSize: CGSize
            var cropOrigin: CGPoint
            var cropSize: CGSize

            func crop(_ scale: CGFloat) -> CGRect {
                CGRect(
                    x: (cropOrigin.x * scale).rounded(), y: (cropOrigin.y * scale).rounded(),
                    width: cropSize.width * scale, height: cropSize.height * scale
                )
            }
        }

        /// Page thumb: the page scaled to fill 176×228, top-aligned (a taller page loses its bottom).
        static func pageFrame(pageSize: CGSize) -> Frame {
            let s = max(Self.pageSize.width / pageSize.width, Self.pageSize.height / pageSize.height)
            return Frame(
                renderSize: CGSize(width: pageSize.width * s, height: pageSize.height * s),
                cropOrigin: .zero,
                cropSize: Self.pageSize
            )
        }

        /// Cover: `coverWidth` page points from `coverOrigin`, scaled to 344 wide.
        static func coverFrame(pageSize: CGSize) -> Frame {
            let s = coverSize.width / coverWidth
            return Frame(
                renderSize: CGSize(width: pageSize.width * s, height: pageSize.height * s),
                cropOrigin: CGPoint(x: coverOrigin.x * s, y: coverOrigin.y * s), cropSize: coverSize
            )
        }

        enum RenderError: Error {
            case crop, resample, encode
        }

        /// `rect` (pixels) of `image`; outside the image is paper-less transparent, so renders are made
        /// large enough that it never is.
        static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
            guard let cropped = image.cropping(to: rect) else { throw RenderError.crop }
            return cropped
        }

        /// `image` (a whole page) drawn into `size` points at `scale`, then cropped.
        static func resample(_ image: CGImage, to size: CGSize, scale: CGFloat, crop: CGRect) throws -> CGImage {
            let (w, h) = (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw RenderError.resample }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let whole = context.makeImage() else { throw RenderError.resample }
            return try Self.crop(whole, to: crop)
        }

        /// `Thread.isMainThread` for async contexts (the debug assertion that no thumbnail work runs on main).
        public static func isMainThread() -> Bool {
            Thread.isMainThread
        }

        /// Encodes HEIC and writes it via a temp file + rename, so a reader never sees a partial file.
        static func writeHEIC(_ image: CGImage, to url: URL, quality: Double) throws {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
                throw RenderError.encode
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw RenderError.encode }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data as Data).write(to: url, options: .atomic)
        }
    }

    @MainActor
    public extension ThumbnailService {
        /// A renderer over an engine: `render(page:size:scale:)` sets up on main and draws off it.
        static func renderer(_ engine: any InkEngine) -> Renderer {
            let box = EngineBox(engine)
            return { page, size, scale in await box.render(page, size, scale) }
        }
    }

    /// Sendable handle on a main-actor engine.
    @MainActor
    private final class EngineBox {
        let engine: any InkEngine

        init(_ engine: any InkEngine) {
            self.engine = engine
        }

        func render(_ page: PageSnapshot, _ size: CGSize, _ scale: CGFloat) async -> CGImage? {
            await engine.render(page: page, size: size, scale: scale)
        }
    }
#endif

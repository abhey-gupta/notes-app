import Document
import Foundation
import InkModel

/// What to generate. Equal specs give byte-identical packages.
public struct FixtureSpec: Hashable, Sendable {
    /// Strokes per page on average (ARCHITECTURE.md §12).
    public static let defaultStrokesPerPage = 400

    /// Page count (≥ 1).
    public var pages: Int
    /// Everything else derives from this.
    public var seed: UInt64
    /// Mean strokes per page; each page gets 85–115 % of it.
    public var strokesPerPage: Int
    /// Paper color.
    public var theme: PaperTheme
    /// Notebook paper; `nil` picks one from the seed (lined most often). Pages mix in other templates.
    public var paper: PaperStyle?

    /// Creates a spec.
    public init(
        pages: Int,
        seed: UInt64 = 1,
        strokesPerPage: Int = FixtureSpec.defaultStrokesPerPage,
        theme: PaperTheme = .white,
        paper: PaperStyle? = nil
    ) {
        self.pages = pages
        self.seed = seed
        self.strokesPerPage = strokesPerPage
        self.theme = theme
        self.paper = paper
    }
}

/// Deterministic synthetic notebooks with realistic handwriting density, for perf tests, dev and
/// screenshots (ARCHITECTURE.md §12).
///
/// Pure function of the ``FixtureSpec``: IDs are UUIDv7s minted from a synthetic clock and the seeded
/// stream, dates are fixed, no system randomness or time is read. Each page has its own stream keyed by
/// `(seed, index)`, so page *i* has the same ink in a 10- and a 300-page fixture of one seed (IDs differ).
public struct FixtureGenerator: Sendable {
    /// Unix ms of 2026-01-01T00:00:00Z: fixture notebooks are "created" on a seed-dependent day after it.
    static let epochMilliseconds: UInt64 = 1_767_225_600_000
    /// Synthetic time between consecutive pages' first strokes.
    static let pageMilliseconds: UInt64 = 30 * 60 * 1000

    public let spec: FixtureSpec
    private let createdMilliseconds: UInt64
    private let paper: PaperStyle
    private let cover: CoverColor
    private let notebookID: NotebookID
    private let pageIDs: [PageID]

    public init(_ spec: FixtureSpec) {
        precondition(spec.pages >= 1, "fixture needs at least one page")
        precondition(spec.strokesPerPage >= 0, "strokes per page must be non-negative")
        self.spec = spec
        var rng = SeededRandom(seed: spec.seed, salt: 0)
        createdMilliseconds = Self.epochMilliseconds + UInt64(rng.int(0 ... 364)) * 86_400_000
        paper = spec.paper ?? PaperStyle.allCases[rng.weighted([2, 6, 2, 2, 1])]
        cover = rng.pick(CoverColor.allCases)
        // IDs also depend on the page count so different fixtures never share an ID.
        var ids = SeededRandom(seed: spec.seed, salt: 0x1D5 ^ UInt64(spec.pages) << 32)
        notebookID = NotebookID(uuid: UUIDv7.make(milliseconds: createdMilliseconds, randA: 0, randB: ids.next()))
        let created = createdMilliseconds
        pageIDs = (0 ..< spec.pages).map { i in
            PageID(uuid: UUIDv7.make(
                milliseconds: created + UInt64(i) * Self.pageMilliseconds,
                randA: UInt16(truncatingIfNeeded: i),
                randB: ids.next()
            ))
        }
    }

    /// Package directory name used by the CLI: `<pages>-pages.nb`.
    public var defaultPackageName: String {
        "\(spec.pages)-pages.\(NotebookPackage.pathExtension)"
    }

    /// Notebook metadata (page order included).
    public var notebook: Notebook {
        let created = Date(timeIntervalSince1970: Double(createdMilliseconds) / 1000)
        let modified = Date(timeIntervalSince1970: Double(lastStrokeMilliseconds) / 1000)
        return Notebook(
            id: notebookID,
            title: "Fixture \(spec.pages)p · seed \(spec.seed)",
            cover: cover,
            paper: paper,
            theme: spec.theme,
            pageSize: Notebook.a4Portrait,
            pages: pageIDs,
            createdAt: created,
            modifiedAt: modified,
            rev: UInt64(spec.pages)
        )
    }

    /// Page `index` (in `0..<pages`) with its ink. `rev` is the stroke count (one add per stroke).
    public func page(at index: Int) -> Page {
        var rng = SeededRandom(seed: spec.seed, salt: UInt64(index) + 1)
        var handRNG = SeededRandom(seed: spec.seed, salt: 0x4A4E)
        let hand = Hand(&handRNG)
        let template: PageTemplate = rng.chance(0.75) ? paper.defaultTemplate : rng.pick(Self.otherTemplates)
        let target = Int((Float(spec.strokesPerPage) * rng.float(0.85 ... 1.15)).rounded())
        let writer = InkWriter(
            rng: SeededRandom(seed: rng.next()),
            hand: hand,
            startMilliseconds: createdMilliseconds + UInt64(index) * Self.pageMilliseconds,
            capacity: target
        )
        let size = Notebook.a4Portrait
        let strokes = PageComposer(ink: writer, template: template, pageSize: (Float(size.width), Float(size.height)), target: target)
            .compose()
        return Page(id: pageIDs[index], template: template, strokes: strokes, rev: UInt64(strokes.count))
    }

    /// All pages, generated lazily in order.
    public var pages: LazyMapSequence<Range<Int>, Page> {
        (0 ..< spec.pages).lazy.map(page(at:))
    }

    /// Writes the package at `url` (which must not exist) via ``NotebookPackage/create(at:notebook:pages:)``,
    /// one page in memory at a time.
    @discardableResult
    public func write(to url: URL) throws(DocumentError) -> FixtureReport {
        var strokes = 0
        var samples = 0
        let counted = pages.map { page in
            strokes += page.strokes.count
            samples += page.strokes.reduce(0) { $0 + $1.samples.count }
            return page
        }
        let package = try NotebookPackage.create(at: url, notebook: notebook, pages: counted)
        return FixtureReport(package: package, strokes: strokes, samples: samples, bytes: Self.size(of: url))
    }

    /// Total size of the regular files under `url`.
    static func size(of url: URL) -> Int {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private static let otherTemplates: [PageTemplate] = [
        .blank, .lined(spacing: 24), .lined(spacing: 32), .dotted(spacing: 20), .grid(spacing: 20), .grid(spacing: 16), .cornell,
    ]

    /// Last page's start plus a few minutes of writing: the notebook's `modifiedAt`.
    private var lastStrokeMilliseconds: UInt64 {
        createdMilliseconds + UInt64(spec.pages - 1) * Self.pageMilliseconds + 10 * 60 * 1000
    }
}

/// What ``FixtureGenerator/write(to:)`` produced.
public struct FixtureReport: Sendable {
    /// The new package.
    public var package: NotebookPackage
    /// Strokes across all pages.
    public var strokes: Int
    /// Samples across all strokes.
    public var samples: Int
    /// Bytes of all files in the package.
    public var bytes: Int
}

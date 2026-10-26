import CoreGraphics
import Foundation
import InkModel

/// Where a page's background comes from (§4.5). Day 0 only has ``template`` (the page's
/// ``PageEntry/template``); `.pdf(file, pageIndex)` is reserved for PDF import.
///
/// Persisted as `{"kind": "template"}`; omitted from the manifest while it is ``template``.
public enum PageBackground: Hashable, Sendable, Codable {
    /// Procedural template.
    case template

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        guard kind == "template" else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown background kind \(kind)")
        }
        self = .template
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("template", forKey: .kind)
    }
}

/// Per-page metadata kept in the manifest, so pages can be listed and laid out without opening stroke files.
public struct PageEntry: Hashable, Sendable, Identifiable {
    /// Page identity; also names `pages/<id>.strokes`.
    public let id: PageID
    /// Background template.
    public var template: PageTemplate
    /// Background source (reserved for PDF import).
    public var background: PageBackground
    /// ``Page/rev`` as of the last save.
    public var rev: UInt64
    /// Keys this version does not know, preserved round-trip.
    public var extra: [String: JSONValue]

    /// Creates an entry.
    public init(
        id: PageID,
        template: PageTemplate,
        background: PageBackground = .template,
        rev: UInt64 = 0,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.template = template
        self.background = background
        self.rev = rev
        self.extra = extra
    }
}

extension PageEntry: Codable {
    private static let known: Set<String> = ["id", "template", "background", "rev"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(
            id: c.decode(PageID.self, forKey: AnyCodingKey("id")),
            template: c.decode(PageTemplate.self, forKey: AnyCodingKey("template")),
            background: c.decodeIfPresent(PageBackground.self, forKey: AnyCodingKey("background")) ?? .template,
            rev: c.decode(UInt64.self, forKey: AnyCodingKey("rev")),
            extra: c.unknownKeys(excluding: Self.known)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encode(template, forKey: AnyCodingKey("template"))
        if background != .template {
            try c.encode(background, forKey: AnyCodingKey("background"))
        }
        try c.encode(rev, forKey: AnyCodingKey("rev"))
        try c.encodeUnknownKeys(extra, excluding: Self.known)
    }
}

/// Contents of `manifest.json`: notebook metadata plus per-page entries in page order.
///
/// Page order is ``Notebook/pages`` on ``notebook``; per-page metadata is looked up by ID (pages without
/// an explicit entry get the notebook paper's default template, rev 0). JSON layout: a flat object with
/// `formatVersion`, the ``Notebook`` fields (`pageExtension: {left, right}` only once a page was widened,
/// #129), and `pages: [PageEntry]`; keys sorted, dates as Unix
/// milliseconds. Unknown keys at either level survive decode → encode.
public struct Manifest: Hashable, Sendable {
    /// Format version written by, and the newest readable by, this build (§4.5). 2: stroke files and
    /// journals carry PencilKit rendering data (#71).
    public static let formatVersion = 2

    /// Version this manifest was decoded from (``formatVersion`` for new ones). Older packages are
    /// migrated on open (``NotebookPackage/open(at:)``). Not part of equality.
    public internal(set) var sourceFormatVersion = Manifest.formatVersion
    /// Notebook metadata; ``Notebook/pages`` is the page order.
    public var notebook: Notebook
    /// Top-level keys this version does not know, preserved round-trip.
    public var extra: [String: JSONValue]
    private var entries: [PageID: PageEntry]

    /// Creates a manifest for `notebook`. Dates are rounded to milliseconds (the stored precision).
    /// - Parameter entries: Per-page metadata; order is irrelevant (``Notebook/pages`` decides it) and
    ///   entries for pages not in the notebook are ignored.
    public init(notebook: Notebook, entries: [PageEntry] = [], extra: [String: JSONValue] = [:]) {
        self.notebook = Self.roundingDates(notebook)
        self.extra = extra
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Entries in page order.
    public var pages: [PageEntry] {
        notebook.pages.map(defaultedEntry)
    }

    /// Entry for `id`, or `nil` if the page is not in the notebook.
    public func entry(for id: PageID) -> PageEntry? {
        notebook.pages.contains(id) ? defaultedEntry(id) : nil
    }

    /// Replaces the entry for an existing page.
    public mutating func updateEntry(_ entry: PageEntry) throws(DocumentError) {
        guard notebook.pages.contains(entry.id) else { throw .unknownPage(entry.id) }
        entries[entry.id] = entry
    }

    /// Inserts a page at `index` (`0...pageCount`).
    public mutating func insertPage(_ entry: PageEntry, at index: Int) throws(DocumentError) {
        guard !notebook.pages.contains(entry.id) else { throw .duplicatePage(entry.id) }
        guard index >= 0, index <= notebook.pages.count else { throw .pageIndexOutOfRange(index) }
        notebook.pages.insert(entry.id, at: index)
        entries[entry.id] = entry
    }

    /// Removes a page.
    public mutating func removePage(_ id: PageID) throws(DocumentError) {
        guard let index = notebook.pages.firstIndex(of: id) else { throw .unknownPage(id) }
        notebook.pages.remove(at: index)
        entries[id] = nil
    }

    /// Moves the page at `source` so it ends up at `destination` (both in `0..<pageCount`).
    public mutating func movePage(from source: Int, to destination: Int) throws(DocumentError) {
        let range = notebook.pages.indices
        guard range.contains(source) else { throw .pageIndexOutOfRange(source) }
        guard range.contains(destination) else { throw .pageIndexOutOfRange(destination) }
        notebook.pages.insert(notebook.pages.remove(at: source), at: destination)
    }

    /// JSON bytes: sorted keys, pretty-printed, deterministic for equal manifests.
    public func encoded() throws(DocumentError) -> Data {
        var seen = Set<PageID>()
        for id in notebook.pages where !seen.insert(id).inserted {
            throw .duplicatePage(id)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw .corruptManifest(reason: "encode: \(error)")
        }
    }

    /// Decodes manifest bytes.
    /// - Throws: ``DocumentError/unsupportedFormatVersion(found:supported:)`` for newer manifests (checked
    ///   before anything else is read), ``DocumentError/corruptManifest(reason:)`` otherwise.
    public static func decode(_ data: Data) throws(DocumentError) -> Manifest {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch let error as DocumentError {
            throw error
        } catch {
            throw .corruptManifest(reason: "\(error)")
        }
    }

    /// Equal when notebook, extras and the (defaulted) entries in page order are equal.
    public static func == (lhs: Manifest, rhs: Manifest) -> Bool {
        lhs.notebook == rhs.notebook && lhs.extra == rhs.extra && lhs.pages == rhs.pages
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(notebook)
        hasher.combine(extra)
        hasher.combine(pages)
    }

    private func defaultedEntry(_ id: PageID) -> PageEntry {
        entries[id] ?? PageEntry(id: id, template: notebook.paper.defaultTemplate)
    }

    private static func roundingDates(_ n: Notebook) -> Notebook {
        Notebook(
            id: n.id, title: n.title, cover: n.cover, paper: n.paper, theme: n.theme, keepsExactColors: n.keepsExactColors,
            pageSize: n.pageSize, pageExtension: n.pageExtension, pages: n.pages, createdAt: n.createdAt.roundedToMilliseconds,
            modifiedAt: n.modifiedAt.roundedToMilliseconds, rev: n.rev
        )
    }
}

extension Manifest: Codable {
    private enum Key: String, CaseIterable {
        case formatVersion, id, title, cover, paper, theme, keepsExactColors, pageSize, pageExtension, createdAt, modifiedAt, rev, pages

        var key: AnyCodingKey {
            AnyCodingKey(rawValue)
        }
    }

    private struct Size: Codable {
        var width: Double
        var height: Double
    }

    private struct Extension: Codable {
        var left: Double
        var right: Double
    }

    private static let known = Set(Key.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let version = try c.decode(Int.self, forKey: Key.formatVersion.key)
        guard version >= 1 else { throw DocumentError.corruptManifest(reason: "formatVersion \(version)") }
        guard version <= Self.formatVersion else {
            throw DocumentError.unsupportedFormatVersion(found: version, supported: Self.formatVersion)
        }
        let pages = try c.decode([PageEntry].self, forKey: Key.pages.key)
        var seen = Set<PageID>()
        for page in pages where !seen.insert(page.id).inserted {
            throw DocumentError.corruptManifest(reason: "page \(page.id) listed twice")
        }
        let size = try c.decode(Size.self, forKey: Key.pageSize.key)
        let notebook = try Notebook(
            id: c.decode(NotebookID.self, forKey: Key.id.key),
            title: c.decode(String.self, forKey: Key.title.key),
            cover: c.decode(CoverColor.self, forKey: Key.cover.key),
            paper: c.decode(PaperStyle.self, forKey: Key.paper.key),
            theme: c.decode(PaperTheme.self, forKey: Key.theme.key),
            keepsExactColors: c.decode(Bool.self, forKey: Key.keepsExactColors.key),
            pageSize: CGSize(width: size.width, height: size.height),
            pageExtension: c.decodeIfPresent(Extension.self, forKey: Key.pageExtension.key)
                .map { PageExtension(left: $0.left, right: $0.right) } ?? .none,
            pages: pages.map(\.id),
            createdAt: Date(unixMilliseconds: c.decode(Int64.self, forKey: Key.createdAt.key)),
            modifiedAt: Date(unixMilliseconds: c.decode(Int64.self, forKey: Key.modifiedAt.key)),
            rev: c.decode(UInt64.self, forKey: Key.rev.key)
        )
        try self.init(notebook: notebook, entries: pages, extra: c.unknownKeys(excluding: Self.known))
        sourceFormatVersion = version
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        let n = notebook
        try c.encode(Self.formatVersion, forKey: Key.formatVersion.key)
        try c.encode(n.id, forKey: Key.id.key)
        try c.encode(n.title, forKey: Key.title.key)
        try c.encode(n.cover, forKey: Key.cover.key)
        try c.encode(n.paper, forKey: Key.paper.key)
        try c.encode(n.theme, forKey: Key.theme.key)
        try c.encode(n.keepsExactColors, forKey: Key.keepsExactColors.key)
        try c.encode(Size(width: Double(n.pageSize.width), height: Double(n.pageSize.height)), forKey: Key.pageSize.key)
        if !n.pageExtension.isNone {
            let e = n.pageExtension
            try c.encode(Extension(left: Double(e.left), right: Double(e.right)), forKey: Key.pageExtension.key)
        }
        try c.encode(n.createdAt.unixMilliseconds, forKey: Key.createdAt.key)
        try c.encode(n.modifiedAt.unixMilliseconds, forKey: Key.modifiedAt.key)
        try c.encode(n.rev, forKey: Key.rev.key)
        try c.encode(pages, forKey: Key.pages.key)
        try c.encodeUnknownKeys(extra, excluding: Self.known)
    }
}

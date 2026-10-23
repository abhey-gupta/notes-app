import Foundation
import InkModel

/// A notebook on disk: a `.nb` directory package (ARCHITECTURE.md §4.2).
///
/// ```
/// <notebookID>.nb/
///   manifest.json            Manifest (formatVersion, notebook fields, page entries in order)
///   pages/<pageID>.strokes   StrokeCodec file; absent = page has no strokes yet
///   pages/<pageID>.wal       autosave journal, reserved for the WAL (§4.4)
///   thumbs/<pageID>.heic     page thumbnail;  thumbs/cover.heic  library cover
/// ```
///
/// A value holding the package URL and the manifest as last written. Reads are page-scoped:
/// ``open(at:)`` reads only `manifest.json`, ``loadPage(_:)`` only that page's stroke file. Every file
/// write is atomic (temp file + barrier `fsync` + `rename`). Mutating methods write first and update
/// ``manifest`` only on success. Not synchronized: confine a package to one actor (``DocumentStore``).
public struct NotebookPackage: Sendable {
    /// Package directory extension.
    public static let pathExtension = "nb"
    /// Exported UTType (declared in `project.yml`), conforming to `com.apple.package`.
    public static let typeIdentifier = "com.abhey.notespace.notebook"

    /// Package root.
    public let url: URL
    /// Manifest as last read or written.
    public private(set) var manifest: Manifest

    private init(url: URL, manifest: Manifest) {
        self.url = url
        self.manifest = manifest
    }

    // MARK: Locations

    /// `Documents/Notebooks`, where packages live (§15.7).
    public static func notebooksDirectory(in documents: URL = .documentsDirectory) -> URL {
        documents.appending(path: "Notebooks", directoryHint: .isDirectory)
    }

    /// Package URL for a notebook: `<directory>/<notebookID>.nb`. Named by ID so renames never move files.
    public static func url(for id: NotebookID, in directory: URL) -> URL {
        directory.appending(path: "\(id).\(pathExtension)", directoryHint: .isDirectory)
    }

    /// Every `.nb` package directly in `directory`, sorted by name; empty if the directory does not exist.
    /// For rebuilding the library index (§8).
    public static func packageURLs(in directory: URL) throws(DocumentError) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == pathExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw .io(directory, reason: "\(error)")
        }
    }

    /// `manifest.json`.
    public var manifestURL: URL {
        Self.manifestURL(in: url)
    }

    /// `pages/`.
    public var pagesDirectory: URL {
        url.appending(path: "pages", directoryHint: .isDirectory)
    }

    /// `thumbs/`.
    public var thumbnailsDirectory: URL {
        url.appending(path: "thumbs", directoryHint: .isDirectory)
    }

    /// `pages/<id>.strokes`.
    public func strokesURL(for id: PageID) -> URL {
        pagesDirectory.appending(path: "\(id).strokes", directoryHint: .notDirectory)
    }

    /// `pages/<id>.wal`: the page's autosave journal (§4.4).
    public func journalURL(for id: PageID) -> URL {
        pagesDirectory.appending(path: "\(id).wal", directoryHint: .notDirectory)
    }

    /// `thumbs/<id>.heic`: page thumbnail (§5.5).
    public func thumbnailURL(for id: PageID) -> URL {
        thumbnailsDirectory.appending(path: "\(id).heic", directoryHint: .notDirectory)
    }

    /// `thumbs/cover.heic`: first page at cover size for library recents (§5.5).
    public var coverThumbnailURL: URL {
        thumbnailsDirectory.appending(path: "cover.heic", directoryHint: .notDirectory)
    }

    // MARK: Create / open

    /// Writes a new package at `url` (e.g. ``url(for:in:)``). Parent directories are created.
    ///
    /// The package is assembled in a hidden sibling directory and renamed into place, so a crash never
    /// leaves a half-written `.nb`. A notebook with no pages gets one (paper's default template).
    /// - Throws: ``DocumentError/alreadyExists(_:)`` if anything is at `url`.
    public static func create(at url: URL, notebook: Notebook) throws(DocumentError) -> NotebookPackage {
        try create(at: url, notebook: notebook, pages: EmptyCollection())
    }

    /// Writes a new package with ink: ``create(at:notebook:)`` plus a stroke file per non-empty page, all
    /// inside the staging directory, so the package appears complete or not at all (import, duplicate,
    /// fixtures). Writes only what it is given (no clock, no fresh IDs), so equal inputs give equal bytes.
    ///
    /// `pages` is consumed once, in order, one page at a time: a lazy sequence keeps memory at one page.
    /// - Parameter pages: Page order, templates, revs and strokes. If non-empty it replaces `notebook.pages`.
    /// - Throws: ``DocumentError/alreadyExists(_:)``, ``DocumentError/duplicatePage(_:)``,
    ///   ``DocumentError/pageTooLarge(_:)``, ``DocumentError/io(_:reason:)``.
    public static func create(at url: URL, notebook: Notebook, pages: some Sequence<Page>) throws(DocumentError) -> NotebookPackage {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path(percentEncoded: false)) else { throw .alreadyExists(url) }
        let staging = url.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).staging", directoryHint: .isDirectory)
        let stagingPages = staging.appending(path: "pages", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: stagingPages, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging.appending(path: "thumbs"), withIntermediateDirectories: false)
            var notebook = notebook
            var entries: [PageEntry] = []
            for page in pages {
                entries.append(PageEntry(id: page.id, template: page.template, rev: page.rev))
                guard !page.strokes.isEmpty else { continue }
                let data: Data
                do {
                    data = try StrokeCodec.encode(page.strokes)
                } catch {
                    throw DocumentError.pageTooLarge(page.id)
                }
                try data.write(to: stagingPages.appending(path: "\(page.id).strokes", directoryHint: .notDirectory))
            }
            if !entries.isEmpty {
                notebook.pages = entries.map(\.id)
            } else if notebook.pages.isEmpty {
                notebook.pages = [PageID()]
            }
            let manifest = Manifest(notebook: notebook, entries: entries)
            try manifest.encoded().write(to: manifestURL(in: staging))
            try fm.moveItem(at: staging, to: url)
            return NotebookPackage(url: url, manifest: manifest)
        } catch {
            try? fm.removeItem(at: staging)
            if let error = error as? DocumentError {
                throw error
            }
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                throw .alreadyExists(url)
            }
            throw .io(url, reason: "\(error)")
        }
    }

    /// Opens a package, reading only `manifest.json`.
    public static func open(at url: URL) throws(DocumentError) -> NotebookPackage {
        try NotebookPackage(url: url, manifest: readManifest(at: url))
    }

    /// Reads and decodes a package's manifest without opening it (library index rebuild).
    public static func readManifest(at url: URL) throws(DocumentError) -> Manifest {
        let file = manifestURL(in: url)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw .notFound(url)
        } catch {
            throw .io(file, reason: "\(error)")
        }
        return try Manifest.decode(data)
    }

    // MARK: Pages

    /// Loads one page: its manifest entry plus `pages/<id>.strokes`, nothing else.
    /// A page with no stroke file yet is empty.
    public func loadPage(_ id: PageID) throws(DocumentError) -> Page {
        try loadPageAndIdentity(id).page
    }

    /// ``loadPage(_:)`` plus the identity of the stroke file it read (journal base check).
    func loadPageAndIdentity(_ id: PageID) throws(DocumentError) -> (page: Page, identity: StrokesIdentity) {
        guard let entry = manifest.entry(for: id) else { throw .unknownPage(id) }
        let file = strokesURL(for: id)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return (Page(id: id, template: entry.template, rev: entry.rev), .absent)
        } catch {
            throw .io(file, reason: "\(error)")
        }
        let strokes: [Stroke]
        do {
            strokes = try StrokeCodec.decode(data)
        } catch let .unsupportedVersion(found, supported) {
            throw .unsupportedFormatVersion(found: Int(found), supported: Int(supported))
        } catch {
            throw .corruptPage(id, error)
        }
        return (Page(id: id, template: entry.template, strokes: strokes, rev: entry.rev), StrokesIdentity(data))
    }

    /// Loads the page at `index` in page order.
    public func loadPage(at index: Int) throws(DocumentError) -> Page {
        let pages = manifest.notebook.pages
        guard pages.indices.contains(index) else { throw .pageIndexOutOfRange(index) }
        return try loadPage(pages[index])
    }

    /// Saves one page; see ``savePages(_:)``.
    public mutating func savePage(_ page: Page) throws(DocumentError) {
        try savePages(CollectionOfOne(page))
    }

    /// Checkpoints pages: rewrites each stroke file atomically, then the manifest once (entries take each
    /// page's `rev` and template; notebook `rev`/`modifiedAt` bumped). All pages are encoded before
    /// anything is written.
    public mutating func savePages(_ pages: some Collection<Page>) throws(DocumentError) {
        _ = try checkpoint(pages)
    }

    /// ``savePages(_:)``, returning the identity of each stroke file written. Stroke files, then the
    /// manifest, are each barrier-synced and their directories synced, so once this returns the new
    /// state is ordered on media ahead of anything written after (e.g. journal deletion).
    mutating func checkpoint(_ pages: some Collection<Page>) throws(DocumentError) -> [PageID: StrokesIdentity] {
        var next = manifest
        var files: [(URL, Data)] = []
        files.reserveCapacity(pages.count)
        for page in pages {
            guard var entry = next.entry(for: page.id) else { throw .unknownPage(page.id) }
            entry.rev = page.rev
            entry.template = page.template
            try next.updateEntry(entry)
            do {
                try files.append((strokesURL(for: page.id), StrokeCodec.encode(page.strokes)))
            } catch {
                throw .pageTooLarge(page.id)
            }
        }
        var identities: [PageID: StrokesIdentity] = [:]
        for (page, (file, data)) in zip(pages, files) {
            try Self.writeAtomically(data, to: file)
            identities[page.id] = StrokesIdentity(data)
        }
        FileIO.syncDirectory(pagesDirectory)
        try commit(next)
        FileIO.syncDirectory(url)
        return identities
    }

    /// Inserts an empty page (no stroke file is written until it has ink).
    /// - Parameters:
    ///   - index: Position in `0...pageCount`; `nil` appends.
    ///   - template: Background; `nil` uses the notebook paper's default.
    /// - Returns: The new page's ID.
    @discardableResult
    public mutating func insertPage(at index: Int? = nil, template: PageTemplate? = nil) throws(DocumentError) -> PageID {
        var next = manifest
        let id = PageID()
        let entry = PageEntry(id: id, template: template ?? next.notebook.paper.defaultTemplate)
        try next.insertPage(entry, at: index ?? next.notebook.pages.count)
        try commit(next)
        return id
    }

    /// Removes a page from the manifest, then deletes its stroke file, journal and thumbnail.
    /// A crash in between leaves only unreferenced files, never a dangling reference.
    public mutating func deletePage(_ id: PageID) throws(DocumentError) {
        var next = manifest
        try next.removePage(id)
        try commit(next)
        for file in [strokesURL(for: id), journalURL(for: id), thumbnailURL(for: id)] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Moves the page at `source` to `destination` (both in `0..<pageCount`).
    public mutating func movePage(from source: Int, to destination: Int) throws(DocumentError) {
        var next = manifest
        try next.movePage(from: source, to: destination)
        try commit(next)
    }

    /// Sets the background template of `ids` (all pages if `nil`) and writes the manifest.
    public mutating func setTemplate(_ template: PageTemplate, for ids: [PageID]? = nil) throws(DocumentError) {
        var next = manifest
        for id in ids ?? next.notebook.pages {
            guard var entry = next.entry(for: id) else { throw .unknownPage(id) }
            entry.template = template
            try next.updateEntry(entry)
        }
        try commit(next)
    }

    /// Changes notebook metadata (title, cover, paper, theme…) and writes the manifest.
    public mutating func updateNotebook(_ change: (inout Notebook) -> Void) throws(DocumentError) {
        var next = manifest
        change(&next.notebook)
        try commit(next)
    }

    // MARK: Private

    private static func manifestURL(in package: URL) -> URL {
        package.appending(path: "manifest.json", directoryHint: .notDirectory)
    }

    /// Bumps the notebook's `rev`/`modifiedAt`, writes the manifest atomically, then adopts it.
    private mutating func commit(_ next: Manifest) throws(DocumentError) {
        var next = next
        next.notebook.markModified(at: Date().roundedToMilliseconds)
        try Self.writeAtomically(next.encoded(), to: manifestURL)
        manifest = next
    }

    /// Writes `data` to a hidden temp file beside `url`, barrier-syncs it, then `rename`s it over `url`.
    static func writeAtomically(_ data: Data, to url: URL) throws(DocumentError) {
        try FileIO.writeAtomically(data, to: url)
    }
}

/// Identifies one version of a page's stroke file: its length and the CRC-32 stored in its header
/// (which covers the whole file). A journal records the identity of the file it was started on; if the
/// file on disk no longer matches, a checkpoint already folded the journal in (§4.4).
struct StrokesIdentity: Hashable, Sendable {
    /// File length in bytes; `0` if absent.
    var length: UInt64
    /// Header CRC-32; `0` if absent.
    var crc: UInt32

    /// No stroke file (a real one is never shorter than its 22-byte header).
    static let absent = StrokesIdentity(length: 0, crc: 0)

    init(length: UInt64, crc: UInt32) {
        self.length = length
        self.crc = crc
    }

    /// Identity of stroke-file bytes.
    init(_ data: Data) {
        length = UInt64(data.count)
        guard data.count >= StrokeCodec.headerLength else {
            crc = 0
            return
        }
        crc = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 18, as: UInt32.self)) }
    }
}

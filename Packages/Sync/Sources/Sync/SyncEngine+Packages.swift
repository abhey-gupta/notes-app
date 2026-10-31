import Document
import Foundation
import InkModel
import Library

/// What a pull writes into one existing package: pending pages the device hasn't edited since (`write`),
/// removed pages (`remove`), pages the device edited that stay as they are (`keep`; a conflict upload in
/// `conflicted` when both sides have ink), assets it lacks, and the cover.
struct PackagePlan {
    var write: [PageID: PageRecord] = [:]
    var remove: Set<PageID> = []
    var keep: Set<PageID> = []
    var conflicted: Set<PageID> = []
    var assets: [SyncAsset] = []
    var cover: CoverRecord?
    /// The library's cover changed since the last pass (kept; the push sends it).
    var coverEdited = false

    var writesFiles: Bool {
        !write.isEmpty || !remove.isEmpty || !assets.isEmpty || cover != nil
    }

    /// Folder paths it copies out.
    func blobs(of id: NotebookID) -> [String] {
        var paths = write.compactMap { page, r in r.blob.map { SyncLayout.strokes($0, notebook: id, page: page) } }
        paths += assets.map { SyncLayout.asset($0, notebook: id) }
        if let cover {
            paths.append(SyncLayout.cover(cover.blob, notebook: id))
        }
        return paths
    }

    init(_ record: NotebookRecord, manifest: Manifest, package url: URL) {
        let fm = FileManager.default
        for (page, r) in record.pages.sorted(by: { $0.key < $1.key }) where r.isPending {
            let edited = manifest.entry(for: page).map { e in r.local.map { $0.rev != e.rev } ?? true } ?? false
            let inked = edited && fm.fileExists(atPath: url.appending(path: "pages/\(page).strokes").path(percentEncoded: false))
            if r.removed {
                _ = inked ? keep.insert(page) : remove.insert(page)
            } else if inked, r.blob == nil {
                keep.insert(page)
            } else {
                write[page] = r
                if inked {
                    conflicted.insert(page)
                }
            }
        }
        assets = record.assets.filter { !fm.fileExists(atPath: url.appending(path: $0.path).path(percentEncoded: false)) }.sorted()
        let coverURL = NotebookPackage.thumbnailsDirectory(in: url).appending(path: "cover.heic")
        coverEdited = record.cover.map { $0.local != nil && FileStamp.of(coverURL) != $0.local } ?? false
        cover = record.cover.flatMap { $0.isPending && !coverEdited ? $0 : nil }
    }
}

/// Notebook packages: a new one staged from blobs and adopted, an existing one updated in place.
extension SyncEngine {
    /// A notebook new to this library: staged in `Notebooks/` from blobs, then adopted (filed, maybe trashed).
    func create(_ id: NotebookID, _ state: inout SyncState) async throws(SyncError) -> Bool {
        guard var record = state.notebooks[id] else { return true }
        let order = Self.order(record, local: [], keep: [])
        var values: [NotebookField: JSONValue] = [:]
        for field in NotebookField.manifestFields {
            values[field] = record[field]?.value
        }
        guard var notebook = NotebookField.notebook(id: id, values: values, base: nil, pages: order) else { return false }
        notebook.markModified(at: record.modifiedAt ?? now())
        let pages = order.compactMap { page in record.pages[page].map { (page, $0) } }
        var blobs = pages.compactMap { page, r in r.blob.map { SyncLayout.strokes($0, notebook: id, page: page) } }
        blobs += record.assets.map { SyncLayout.asset($0, notebook: id) }
        blobs += [record.cover].compactMap { $0.map { SyncLayout.cover($0.blob, notebook: id) } }
        guard ready(blobs) else { return false }

        let extra = record[.extra]?.value.decoded([String: JSONValue].self) ?? [:]
        let manifest = Manifest(notebook: notebook, entries: pages.map { $1.meta.entry(id: $0, rev: 1) }, extra: extra)
        let staging = library.locations.notebooksDirectory.appending(path: ".sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        let entry: LibraryEntry
        do {
            try stage(record, id: id, pages: pages, manifest: manifest, at: staging)
            entry = try await library.adoptPackage(at: staging, in: record.folder)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw SyncError(error)
        }
        if record.isTrashed {
            try await perform(.delete(id))
        }
        record.settle(NotebookField.manifestFields + [.folder, .trashed])
        for (page, r) in pages {
            record.pages[page]?.local = LocalPage(stamp: r.stamp, rev: 1, blob: r.blob)
        }
        if record.cover != nil {
            let path = "\(entry.packagePath)/thumbs/cover.heic"
            record.cover?.settle()
            record.cover?.local = FileStamp.of(library.locations.notebooksURL(path))
                ?? FileStamp.of(library.locations.trashDirectory.appending(path: path))
        }
        record.localAssets = record.assets
        record.localRev = nil
        record.materialised = true
        state.notebooks[id] = record
        return true
    }

    /// Fills a staging package: assets, stroke files, cover, then the manifest.
    private func stage(
        _ record: NotebookRecord, id: NotebookID, pages: [(PageID, PageRecord)], manifest: Manifest, at staging: URL
    ) throws(SyncError) {
        do {
            for sub in ["pages", "thumbs"] + SyncAsset.Kind.allCases.map(\.rawValue) {
                try FileManager.default.createDirectory(at: staging.appending(path: sub), withIntermediateDirectories: true)
            }
        } catch {
            throw SyncError(error)
        }
        for asset in record.assets {
            try fs.copyOut(SyncLayout.asset(asset, notebook: id), to: staging.appending(path: asset.path))
        }
        for (page, r) in pages {
            if let blob = r.blob {
                try fs.copyOut(SyncLayout.strokes(blob, notebook: id, page: page), to: staging.appending(path: "pages/\(page).strokes"))
            }
        }
        if let cover = record.cover {
            try fs.copyOut(SyncLayout.cover(cover.blob, notebook: id), to: staging.appending(path: "thumbs/cover.heic"))
        }
        try writeManifest(manifest, to: staging)
    }

    /// Writes merged pages, assets, cover and fields into an existing package (live or trashed).
    func update(_ id: NotebookID, _ state: inout SyncState, local: LocalNotebook) async throws(SyncError) -> Bool {
        guard var record = state.notebooks[id], let manifest = try? NotebookPackage.readManifest(at: local.packageURL) else { return false }
        let plan = PackagePlan(record, manifest: manifest, package: local.packageURL)
        guard ready(plan.blobs(of: id)) else { return false }
        if !plan.writesFiles, !NotebookField.manifestFields.contains(where: { record[$0]?.isPending ?? false }) {
            if plan.coverEdited {
                record.cover?.settle()
            }
            state.notebooks[id] = record
            return true
        }
        try recordConflicts(plan, of: id, in: local.packageURL, state: &state)
        try writeFiles(plan, of: id, in: local.packageURL)
        let (next, revs) = rewritten(manifest, record: record, plan: plan)
        try writeManifest(next, to: local.packageURL)
        if !local.trashed {
            do {
                try await library.didSave(next)
            } catch {
                throw SyncError(error)
            }
        }

        record.settle(NotebookField.manifestFields)
        for (page, r) in plan.write {
            record.pages[page]?.local = LocalPage(stamp: r.stamp, rev: revs[page] ?? 1, blob: r.blob)
            record.pages[page]?.replaced = nil
        }
        for page in plan.remove {
            record.pages[page]?.local = nil
        }
        if plan.cover != nil {
            record.cover?.settle()
            record.cover?.local = FileStamp.of(NotebookPackage.thumbnailsDirectory(in: local.packageURL).appending(path: "cover.heic"))
        } else if plan.coverEdited {
            record.cover?.settle()
        }
        record.localAssets.formUnion(record.assets)
        record.localRev = nil
        state.notebooks[id] = record
        return true
    }

    /// Pages whose shown ink is about to be replaced: the device's own unsent ink is copied into the folder
    /// first (`mine`); a version replaced by an op written without seeing it is still there (``PageRecord/replaced``).
    private func recordConflicts(_ plan: PackagePlan, of id: NotebookID, in url: URL, state: inout SyncState) throws(SyncError) {
        let date = now()
        for (page, r) in plan.write.sorted(by: { $0.key < $1.key }) {
            guard let theirs = r.blob else { continue }
            var mine = r.replaced
            if plan.conflicted.contains(page) {
                let name = SyncLayout.blobName(clock: state.tick(), device: device.id, ext: "strokes")
                try fs.copyIn(url.appending(path: "pages/\(page).strokes"), to: SyncLayout.strokes(name, notebook: id, page: page))
                mine = name
            }
            if let mine {
                state.conflicts.append(Conflict(notebook: id, page: page, theirs: theirs, mine: mine, device: r.stamp.device, since: date))
            }
        }
    }

    /// Assets, stroke files (journals and thumbnails of replaced pages dropped), removed pages, the cover.
    private func writeFiles(_ plan: PackagePlan, of id: NotebookID, in url: URL) throws(SyncError) {
        let fm = FileManager.default
        do {
            for directory in ["pages", "thumbs"] + plan.assets.map(\.kind.rawValue) {
                try fm.createDirectory(at: url.appending(path: directory), withIntermediateDirectories: true)
            }
        } catch {
            throw SyncError(error)
        }
        for asset in plan.assets {
            try replace(url.appending(path: asset.path)) { temp throws(SyncError) in
                try fs.copyOut(SyncLayout.asset(asset, notebook: id), to: temp)
            }
        }
        for (page, r) in plan.write.sorted(by: { $0.key < $1.key }) {
            let target = url.appending(path: "pages/\(page).strokes")
            if let blob = r.blob {
                try replace(target) { temp throws(SyncError) in
                    try fs.copyOut(SyncLayout.strokes(blob, notebook: id, page: page), to: temp)
                }
            } else {
                try? fm.removeItem(at: target)
            }
            Self.dropDerived(of: page, in: url)
        }
        for page in plan.remove {
            try? fm.removeItem(at: url.appending(path: "pages/\(page).strokes"))
            Self.dropDerived(of: page, in: url)
        }
        if let cover = plan.cover {
            try replace(NotebookPackage.thumbnailsDirectory(in: url).appending(path: "cover.heic")) { temp throws(SyncError) in
                try fs.copyOut(SyncLayout.cover(cover.blob, notebook: id), to: temp)
            }
        }
    }

    /// The manifest after the plan: merged fields and order where the library still holds the markers,
    /// written pages at a bumped page `rev`, notebook `rev` bumped. Returns it and the written pages' revs.
    private func rewritten(_ manifest: Manifest, record: NotebookRecord, plan: PackagePlan) -> (Manifest, [PageID: UInt64]) {
        var values: [NotebookField: JSONValue] = [:]
        let current = NotebookField.values(of: manifest)
        for field in NotebookField.manifestFields {
            values[field] = Self.pick(current[field] ?? .null, marker: record[field]?.local, merged: record[field]?.value)
        }
        var merged = record
        if let order = record[.pages], order.local != nil, current[.pages] != order.local {
            merged[.pages]?.value = current[.pages] ?? .array([])
        }
        let localPages = manifest.notebook.pages
        let unsent = localPages.filter { record.pages[$0]?.local == nil && plan.write[$0] == nil }
        let order = Self.order(merged, local: localPages, keep: plan.keep.union(unsent)).filter { !plan.remove.contains($0) }
        var revs: [PageID: UInt64] = [:]
        let entries = order.map { page in
            if let r = plan.write[page] {
                let rev = max(manifest.entry(for: page)?.rev ?? 0, r.local?.rev ?? 0) + 1
                revs[page] = rev
                return r.meta.entry(id: page, rev: rev)
            }
            return manifest.entry(for: page) ?? record.pages[page]?.meta.entry(id: page, rev: 0) ?? PageEntry(id: page, template: .blank)
        }
        var notebook = NotebookField.notebook(id: manifest.notebook.id, values: values, base: manifest.notebook, pages: order)
            ?? manifest.notebook
        notebook.pages = order
        notebook.markModified(at: max(manifest.notebook.modifiedAt, record.modifiedAt ?? .distantPast))
        let extra = values[.extra]?.decoded([String: JSONValue].self) ?? manifest.extra
        return (Manifest(notebook: notebook, entries: entries, extra: extra), revs)
    }

    // MARK: Files

    /// Whether every blob is downloaded; starts downloading the rest (the notebook waits for the next pass).
    func ready(_ paths: [String]) -> Bool {
        var ready = true
        for path in paths where !fs.isDownloaded(path) {
            fs.startDownload(path)
            ready = false
        }
        return ready
    }

    /// Fills a temp file beside `target` (`fill` gets a URL that doesn't exist), then renames it over `target`.
    func replace(_ target: URL, fill: (URL) throws(SyncError) -> Void) throws(SyncError) {
        let fm = FileManager.default
        let temp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fill(temp)
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw SyncError(error)
        }
    }

    func writeManifest(_ manifest: Manifest, to package: URL) throws(SyncError) {
        do {
            try manifest.encoded().write(to: package.appending(path: "manifest.json"), options: .atomic)
        } catch {
            throw SyncError(error)
        }
    }

    /// A replaced page's journal (folded into the stroke file it no longer matches) and thumbnail.
    static func dropDerived(of page: PageID, in package: URL) {
        for file in ["pages/\(page).wal", "thumbs/\(page).heic"] {
            try? FileManager.default.removeItem(at: package.appending(path: file))
        }
    }
}

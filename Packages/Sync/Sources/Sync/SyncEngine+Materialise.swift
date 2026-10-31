import Document
import Foundation
import InkModel
import Library

/// Writing merged state into the library (a pull's second half): folders, then notebooks, then folder
/// removals (so a notebook moved out of a removed folder has left it first).
///
/// A value is written only where the library still holds its marker; where the device changed it since
/// (not pushed yet), the library's value stays and the next push sends it with a later clock. Markers then
/// take the merged value, so whatever the library still differs in is what the push sends.
extension SyncEngine {
    func materialise(
        _ state: inout SyncState,
        report: inout PullReport,
        only: NotebookID? = nil,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws(SyncError) {
        if only == nil {
            try await materialiseFolders(&state, removals: false)
        }
        let pending = state.notebooks.filter { (only == nil || $0.key == only) && $0.value.isPending }.keys.sorted()
        let total = pending.reduce(0) { sum, id in sum + (state.notebooks[id]?.pages.values.count { $0.isPending } ?? 0) }
        var names: [String: String] = [:]
        if pending.contains(where: { !(state.notebooks[$0]?.from.isEmpty ?? true) }) {
            names = Dictionary((try? readDevices())?.map { ($0.id, $0.name) } ?? [], uniquingKeysWith: { first, _ in first })
        }
        var done = 0
        for id in pending {
            guard let record = state.notebooks[id] else { continue }
            let snapshot = await library.snapshot()
            let inLibrary = snapshot.notebook(id) != nil || snapshot.trash.contains { $0.id == id }
            if record.materialised, !record.isDeleted, !inLibrary {
                continue // purged here since the last pass: the push sends the delete, never brought back
            }
            if openNotebooks.contains(id) {
                try await writeLibraryFields(id, &state, snapshot: snapshot)
                if state.notebooks[id]?.isPending == true {
                    state.deferred.insert(id)
                    report.deferred.append(id)
                }
                continue
            }
            let from = record.from.sorted().map { names[$0] ?? $0 }
            progress(SyncProgress(
                direction: .receiving, notebook: record[.title]?.value.decoded(String.self) ?? "", device: from.first, done: done,
                total: total
            ))
            done += record.pages.values.count { $0.isPending }
            let conflicts = state.conflicts.count
            guard try await materialise(id, &state, snapshot: snapshot) else {
                report.waiting.append(id)
                continue
            }
            state.deferred.remove(id)
            state.notebooks[id]?.from = []
            report.applied.append(id)
            report.conflicts += state.conflicts[conflicts...]
            for name in from where !report.fromDevices.contains(name) {
                report.fromDevices.append(name)
            }
        }
        if only == nil {
            try await materialiseFolders(&state, removals: true)
        }
    }

    // MARK: Folders

    /// Creates, renames and moves folders (`removals` false; parents first), or removes them (`removals` true).
    private func materialiseFolders(_ state: inout SyncState, removals: Bool) async throws(SyncError) {
        let pending = state.folders.filter { $0.value.isPending && $0.value.isRemoved == removals }
        guard !pending.isEmpty else { return }
        let local = await Dictionary(library.snapshot().folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func depth(_ id: FolderID) -> Int {
            var depth = 0
            var current = state.folders[id]?.fields["parent"]?.value.folderID
            while let parent = current, depth < state.folders.count {
                depth += 1
                current = state.folders[parent]?.fields["parent"]?.value.folderID
            }
            return depth
        }
        for id in pending.keys.sorted(by: { (depth($0), $0) < (depth($1), $1) }) {
            guard var record = state.folders[id] else { continue }
            let existing = local[id]
            do {
                if removals {
                    if existing != nil {
                        try await library.deleteFolder(id)
                    }
                } else if let existing {
                    let name = Self.pick(.string(existing.name), marker: record.fields["name"]?.local, merged: record.fields["name"]?.value)
                    let parent = Self.pick(
                        NotebookField.value(of: existing.parentID), marker: record.fields["parent"]?.local,
                        merged: record.fields["parent"]?.value
                    )
                    try await upsertFolder(id, name: name, parent: parent)
                } else if record.fields["name"]?.local == nil || record.fields["removed"]?.local == .bool(true) {
                    // Not deleted here since the last pass (that would be pushed): create it.
                    try await upsertFolder(id, name: record.fields["name"]?.value, parent: record.fields["parent"]?.value)
                }
            } catch {
                throw SyncError(error)
            }
            for (key, field) in record.fields {
                record.fields[key]?.local = field.value
            }
            state.folders[id] = record
        }
    }

    private func upsertFolder(_ id: FolderID, name: JSONValue?, parent: JSONValue?) async throws(LibraryError) {
        let name = name?.decoded(String.self) ?? "Folder"
        do {
            try await library.upsertFolder(LibraryFolder(id: id, name: name, parentID: parent?.folderID))
        } catch .unknownFolder {
            try await library.upsertFolder(LibraryFolder(id: id, name: name, parentID: nil))
        }
    }

    // MARK: Notebooks

    /// Writes one notebook; `false` if it has to wait (blobs not downloaded, fields incomplete).
    private func materialise(_ id: NotebookID, _ state: inout SyncState, snapshot: LibrarySnapshot) async throws(SyncError) -> Bool {
        guard var record = state.notebooks[id] else { return true }
        let local = LocalScan.notebooks(in: snapshot, locations: library.locations).first { $0.id == id }
        if record.isDeleted {
            if local != nil {
                try await perform(.purge(id))
            }
            record.materialised = false
            state.notebooks[id] = record
            return true
        }
        guard let local else {
            return try await create(id, &state)
        }
        guard record.materialised else {
            // The library had it before this state knew it (state reset): keep the library's copy; markers
            // stay unknown, so the next push sends all of it again.
            record.materialised = true
            state.notebooks[id] = record
            return true
        }
        guard try await update(id, &state, local: local) else { return false }
        try await writeLibraryFields(id, &state, snapshot: library.snapshot())
        return true
    }

    /// Folder and trash: index-only, so they apply even while an editor has the notebook open.
    private func writeLibraryFields(_ id: NotebookID, _ state: inout SyncState, snapshot: LibrarySnapshot) async throws(SyncError) {
        guard var record = state.notebooks[id] else { return }
        let entry = snapshot.notebook(id)
        let trashedEntry = snapshot.trash.first { $0.id == id }?.entry
        guard let current = entry ?? trashedEntry else { return }
        let folder = Self.pick(NotebookField.value(of: current.folderID), marker: record[.folder]?.local, merged: record.effective(.folder))
        let trashed = Self.pick(.bool(entry == nil), marker: record[.trashed]?.local, merged: record.effective(.trashed))
        if folder.folderID != current.folderID, entry != nil {
            do {
                try await library.move(id, to: folder.folderID)
            } catch .unknownFolder {
                try await perform(.move(id, nil))
            } catch {
                throw SyncError(error)
            }
        }
        if trashed == .bool(true), entry != nil {
            try await perform(.delete(id))
        } else if trashed == .bool(false), entry == nil {
            try await perform(.restore(id))
        }
        record.settle([.folder, .trashed])
        state.notebooks[id] = record
    }

    // MARK: Helpers

    /// The merged value where the library still holds its marker (or has no marker); else the library's.
    static func pick(_ current: JSONValue, marker: JSONValue?, merged: JSONValue?) -> JSONValue {
        guard let merged else { return current }
        return marker == nil || marker == current ? merged : current
    }

    /// Page order: the merged order with pages that are gone dropped; pages the record has that the order
    /// lacks (added by a device whose reorder lost) at the end by ID; `keep` (local pages not sent yet) after
    /// the page they follow locally.
    static func order(_ record: NotebookRecord, local: [PageID], keep: Set<PageID>) -> [PageID] {
        let live = Set(record.pages.filter { !$0.value.removed }.keys)
        var seen: Set<PageID> = []
        var result = (record[.pages]?.value.pageIDs ?? []).filter { (live.contains($0) || keep.contains($0)) && seen.insert($0).inserted }
        result += live.subtracting(seen).subtracting(keep).sorted()
        seen = Set(result)
        for (i, page) in local.enumerated() where keep.contains(page) && !seen.contains(page) {
            let after = local[..<i].last { seen.contains($0) }
            let index = after.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(page, at: index)
            seen.insert(page)
        }
        return result
    }

    /// Library calls the materialiser makes, by name, so their errors map to ``SyncError`` in one place.
    enum LibraryCall {
        case purge(NotebookID)
        case delete(NotebookID)
        case restore(NotebookID)
        case move(NotebookID, FolderID?)
    }

    func perform(_ call: LibraryCall) async throws(SyncError) {
        do {
            switch call {
            case let .purge(id): try await library.purge(id)
            case let .delete(id): try await library.delete(id)
            case let .restore(id): _ = try await library.restore(id)
            case let .move(id, folder): try await library.move(id, to: folder)
            }
        } catch {
            throw SyncError(error)
        }
    }
}

import Foundation
import InkModel
import Library

/// Keeping the folder from growing forever (#225 GC). Each device cleans up only what it wrote (assets of a
/// deleted notebook: whoever notices), and only once every active device (seen in the last
/// ``SyncEngine/activeWindow``) has read past it.
extension SyncEngine {
    /// What a GC pass did.
    public struct GCReport: Hashable, Sendable {
        /// Log entries deleted (folded into `snapshot.json` first).
        public var entries = 0
        /// Blobs deleted.
        public var blobs = 0
    }

    /// Folds this device's log into `log/<me>/snapshot.json`, deletes the entries every active device has
    /// read, and deletes this device's blobs that are unreferenced, have been for ``gcDelay``, and every
    /// active device has read past the op that superseded them. Conflicts older than ``gcDelay`` are dropped.
    @discardableResult
    public func gc(now date: Date? = nil) async throws(SyncError) -> GCReport {
        let date = date ?? now()
        return try await withState { state throws(SyncError) in
            var report = GCReport()
            let others = try readDevices().filter {
                $0.id != device.id && date.timeIntervalSince($0.lastSeen) <= Self.activeWindow
            }
            report.entries = try compactLog(acked: { seq in others.allSatisfy { $0.hasApplied(seq, of: device.id) } })

            let referenced = Self.referenced(state)
            for (path, garbage) in state.garbage.sorted(by: { $0.key < $1.key }) {
                if referenced.contains(path) {
                    state.garbage[path] = nil
                    continue
                }
                guard date.timeIntervalSince(garbage.since) >= Self.gcDelay,
                      others.allSatisfy({ d in garbage.acks.allSatisfy { d.hasApplied($0.value, of: $0.key) } }) else { continue }
                try fs.delete(path)
                state.garbage[path] = nil
                report.blobs += 1
            }
            for conflict in state.conflicts where date.timeIntervalSince(conflict.since) >= Self.gcDelay {
                letGo(conflict, in: &state)
            }
            state.conflicts.removeAll { date.timeIntervalSince($0.since) >= Self.gcDelay }
            return report
        }
    }

    /// Writes the snapshot (this device's ops, latest per field, page, cover…) if entries were added since,
    /// then deletes the entries it covers that `acked`. Returns how many were deleted.
    private func compactLog(acked: (UInt64) -> Bool) throws(SyncError) -> Int {
        let directory = SyncLayout.log(of: device.id)
        let seqs = try fs.list(directory).compactMap(SyncLayout.seq(ofEntry:)).sorted()
        guard let last = seqs.last else { return 0 }
        let previous = try fs.read(SyncLayout.snapshot(of: device.id)).flatMap { SyncJSON.decode(LogEntry.self, from: $0) }
        var covered = previous?.seq ?? 0
        if last > covered {
            var ops = previous?.ops ?? []
            for seq in seqs where seq > covered {
                guard let data = try fs.read(SyncLayout.entry(seq, of: device.id)),
                      let entry = SyncJSON.decode(LogEntry.self, from: data) else { break }
                ops += entry.ops
                covered = seq
            }
            let snapshot = LogEntry(seq: covered, device: device.id, writtenAt: now(), ops: Self.fold(ops))
            try fs.write(SyncLayout.snapshot(of: device.id), SyncJSON.encode(snapshot))
        }
        var deleted = 0
        for seq in seqs where seq <= covered && acked(seq) {
            try fs.delete(SyncLayout.entry(seq, of: device.id))
            deleted += 1
        }
        return deleted
    }

    /// The latest op per thing it sets (notebook field, page, cover, trash state, tombstone, asset, folder
    /// field), in clock order: applying it gives the same state as applying all of `ops`.
    static func fold(_ ops: [SyncOp]) -> [SyncOp] {
        var latest: [String: SyncOp] = [:]
        for (key, op) in ops.flatMap(foldKeys) where latest[key].map({ $0.clock <= op.clock }) ?? true {
            latest[key] = op
        }
        return latest.values.sorted { $0.clock < $1.clock }
    }

    /// What an op sets, one key per thing (a multi-field set split into one op per field).
    private static func foldKeys(_ op: SyncOp) -> [(String, SyncOp)] {
        switch op.change {
        case let .notebookSet(id, fields):
            fields.map { ("\(id)/field/\($0.key)", SyncOp(clock: op.clock, at: op.at, .notebookSet(id, fields: [$0.key: $0.value]))) }
        case let .pageSet(id, page, _, _, _), let .pageRemove(id, page):
            [("\(id)/page/\(page)", op)]
        case let .coverSet(id, _):
            [("\(id)/cover", op)]
        case let .assetAdd(id, asset):
            [("\(id)/asset/\(asset.path)", op)]
        case let .lifecycle(id, lifecycle):
            [("\(id)/\(lifecycle == .delete ? "tombstone" : "trashed")", op)]
        case let .folderSet(id, fields):
            fields.map { ("folder/\(id)/\($0.key)", SyncOp(clock: op.clock, at: op.at, .folderSet(id, fields: [$0.key: $0.value]))) }
        case let .folderRemove(id):
            [("folder/\(id)/removed", op)]
        case .unknown:
            []
        }
    }

    /// Folder paths the state still needs: page and cover blobs of live notebooks, the version each page
    /// shows here, conflict blobs, and assets.
    static func referenced(_ state: SyncState) -> Set<String> {
        var paths: Set<String> = []
        for (id, record) in state.notebooks where !record.isDeleted {
            for (page, r) in record.pages {
                for blob in [r.blob, r.local?.blob, r.replaced].compactMap(\.self) {
                    paths.insert(SyncLayout.strokes(blob, notebook: id, page: page))
                }
            }
            if let cover = record.cover {
                paths.insert(SyncLayout.cover(cover.blob, notebook: id))
            }
            for asset in record.assets {
                paths.insert(SyncLayout.asset(asset, notebook: id))
            }
        }
        for conflict in state.conflicts {
            paths.insert(SyncLayout.strokes(conflict.theirs, notebook: conflict.notebook, page: conflict.page))
            paths.insert(SyncLayout.strokes(conflict.mine, notebook: conflict.notebook, page: conflict.page))
        }
        return paths
    }
}

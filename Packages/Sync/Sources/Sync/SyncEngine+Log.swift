import Document
import Foundation
import InkModel
import Library

/// New ops of one device's log: its snapshot (if past what was applied) and contiguous entries, up to `seq`.
struct LogRead: Sendable {
    var device: String
    var seq: UInt64
    var ops: [SyncOp]
}

/// The folder's files: `sync.json`, logs, device records; and the push's scan and markers.
extension SyncEngine {
    /// Folder ops, then each notebook's ops (``LocalScan``), then tombstones for notebooks the library no
    /// longer has. Only a notebook last seen in the trash gets one: every purge goes through the trash, so a
    /// live notebook that is suddenly missing (an index rebuild that skipped an unreadable package, an empty
    /// snapshot) is a local problem, never a delete sent to every device. Clocks are taken from `state` in
    /// that order.
    static func scan(
        _ snapshot: LibrarySnapshot, locations: LibraryLocations, state: inout SyncState, now date: Date
    ) -> (ops: [SyncOp], scanned: [(LocalNotebook, NotebookChanges)]) {
        var ops = LocalScan.folderOps(snapshot.folders, state: &state, now: date)
        let locals = LocalScan.notebooks(in: snapshot, locations: locations)
        var scanned: [(LocalNotebook, NotebookChanges)] = []
        for local in locals {
            let changes = LocalScan.ops(for: local, state: &state, now: date)
            ops += changes.ops
            scanned.append((local, changes))
        }
        let present = Set(locals.map(\.id))
        for (id, record) in state.notebooks.sorted(by: { $0.key < $1.key })
            where record.materialised && !record.isDeleted && !present.contains(id) && record[.trashed]?.local == .bool(true)
        {
            ops.append(SyncOp(clock: state.tick(), at: date, .lifecycle(id, .delete)))
        }
        return (ops, scanned)
    }

    /// `sync.json`; `nil` if the folder has none (empty, or a #174 backup folder: never read).
    /// - Throws: ``SyncError/newerFormat(_:)`` for a newer format.
    func readFormat() throws(SyncError) -> SyncFormat? {
        guard let data = try fs.read(SyncLayout.format), let format = SyncJSON.decode(SyncFormat.self, from: data) else { return nil }
        guard format.formatVersion <= SyncFormat.formatVersion else { throw .newerFormat(format.formatVersion) }
        return format
    }

    /// New ops per device: the snapshot if it is past what was applied, then contiguous entries.
    func readLogs(after applied: [String: UInt64]) throws(SyncError) -> [LogRead] {
        var result: [LogRead] = []
        for device in try fs.list(SyncLayout.log).sorted() {
            let names = try fs.list(SyncLayout.log(of: device))
            let have = applied[device] ?? 0
            var upTo = have
            var ops: [SyncOp] = []
            if names.contains(SyncLayout.snapshotName), let data = try fs.read(SyncLayout.snapshot(of: device)),
               let snapshot = SyncJSON.decode(LogEntry.self, from: data), snapshot.seq > have
            {
                ops += snapshot.ops
                upTo = snapshot.seq
            }
            for seq in names.compactMap(SyncLayout.seq(ofEntry:)).sorted() where seq > upTo {
                guard seq == upTo + 1, let data = try fs.read(SyncLayout.entry(seq, of: device)),
                      let entry = SyncJSON.decode(LogEntry.self, from: data) else { break }
                ops += entry.ops
                upTo = seq
            }
            if upTo > have {
                result.append(LogRead(device: device, seq: upTo, ops: ops))
            }
        }
        return result
    }

    /// Merges read ops in stamp order and advances `applied`; superseded blobs of this device become garbage.
    func merge(_ logs: [LogRead], into state: inout SyncState) {
        var all: [(read: LogRead, op: SyncOp)] = []
        for log in logs {
            all += log.ops.map { (log, $0) }
            state.applied[log.device] = max(state.applied[log.device] ?? 0, log.seq)
            if log.device == device.id {
                state.nextSeq = max(state.nextSeq, log.seq + 1)
            }
        }
        let stamp = { (item: (read: LogRead, op: SyncOp)) in Stamp(clock: item.op.clock, device: item.read.device) }
        for item in all.sorted(by: { stamp($0) < stamp($1) }) {
            merge(item.op, from: item.read.device, seq: item.read.seq, into: &state)
        }
    }

    /// One op through ``Apply``, noting blobs it leaves unreferenced (``Garbage``).
    func merge(_ op: SyncOp, from writer: String, seq: UInt64, into state: inout SyncState) {
        let before = op.change.notebook.flatMap { state.notebooks[$0] }
        _ = Apply.apply(op, from: writer, to: &state)
        guard let id = op.change.notebook, let before, let after = state.notebooks[id] else { return }
        var dropped: [String] = []
        for (page, old) in before.pages {
            if let blob = old.blob, after.pages[page]?.blob != blob || after.isDeleted {
                dropped.append(SyncLayout.strokes(blob, notebook: id, page: page))
            }
        }
        if let blob = before.cover?.blob, after.cover?.blob != blob || after.isDeleted {
            dropped.append(SyncLayout.cover(blob, notebook: id))
        }
        let garbage = Garbage(since: now(), acks: [writer: seq])
        for path in dropped where SyncLayout.device(ofBlob: path.split(separator: "/").last.map(String.init) ?? "") == device.id {
            state.garbage[path] = state.garbage[path] ?? garbage
        }
        if after.isDeleted, !before.isDeleted {
            for asset in after.assets {
                state.garbage[SyncLayout.asset(asset, notebook: id)] = garbage
            }
        }
    }

    /// Writes `ops` as this device's next log entry (and `sync.json` if the folder has none), then merges them.
    func append(_ ops: [SyncOp], to state: inout SyncState) throws(SyncError) -> URL {
        let own = try fs.list(SyncLayout.log(of: device.id)).compactMap(SyncLayout.seq(ofEntry:))
        let seq = max(state.nextSeq, (own.max() ?? 0) + 1)
        if try readFormat() == nil {
            try fs.write(SyncLayout.format, SyncJSON.encode(SyncFormat(created: now())))
        }
        let path = SyncLayout.entry(seq, of: device.id)
        try fs.write(path, SyncJSON.encode(LogEntry(seq: seq, device: device.id, writtenAt: now(), ops: ops)))
        for op in ops {
            merge(op, from: device.id, seq: seq, into: &state)
        }
        state.applied[device.id] = seq
        state.nextSeq = seq + 1
        return fs.url(path)
    }

    /// Rewrites `devices/<me>.json` when the acks changed, or `force`, or it is an hour old.
    func writeDevice(_ state: SyncState, force: Bool = false) throws(SyncError) {
        let date = now()
        let record = DeviceRecord(
            id: device.id, name: device.name, model: device.model, lastSeen: date, clock: state.clock, applied: state.applied
        )
        if !force, let last = lastDeviceRecord, last.applied == record.applied, last.name == record.name,
           date.timeIntervalSince(last.lastSeen) < Self.lastSeenInterval
        {
            return
        }
        try fs.write(SyncLayout.device(device.id), SyncJSON.encode(record))
        lastDeviceRecord = record
    }

    func readDevices() throws(SyncError) -> [DeviceRecord] {
        var records: [DeviceRecord] = []
        for name in try fs.list(SyncLayout.devices) where name.hasSuffix(".json") {
            if let data = try fs.read("\(SyncLayout.devices)/\(name)"), let record = SyncJSON.decode(DeviceRecord.self, from: data) {
                records.append(record)
            }
        }
        return records
    }

    // MARK: Markers after a push

    /// The library's values a push compared become the notebook's local markers; sent pages and the cover
    /// take the stamps they were sent with.
    static func recordSent(_ changes: NotebookChanges, of local: LocalNotebook, device: String, in state: inout SyncState) {
        var record = state.notebooks[local.id] ?? NotebookRecord()
        for (field, value) in changes.values where record[field] != nil {
            record[field]?.local = value
        }
        for op in changes.ops {
            let stamp = Stamp(clock: op.clock, device: device)
            switch op.change {
            case let .pageSet(_, page, _, _, strokes):
                record.pages[page]?.local = LocalPage(stamp: stamp, rev: changes.pageRevs?[page] ?? 0, blob: strokes)
            case let .pageRemove(_, page):
                record.pages[page]?.local = nil
            case .coverSet:
                record.cover?.localStamp = stamp
                record.cover?.local = changes.cover
            default:
                break
            }
        }
        record.localAssets.formUnion(changes.assets)
        if changes.manifestRev != nil {
            record.localRev = local.entry.rev
        }
        record.materialised = true
        state.notebooks[local.id] = record
    }

    /// Folder markers: the library's name and parent; `removed` false for folders it has, true for the rest.
    static func recordSent(folders: [LibraryFolder], in state: inout SyncState) {
        let present = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in state.folders.keys {
            if let folder = present[id] {
                state.folders[id]?.fields["name"]?.local = .string(folder.name)
                state.folders[id]?.fields["parent"]?.local = NotebookField.value(of: folder.parentID)
                state.folders[id]?.fields["removed"]?.local = .bool(false)
            } else if state.folders[id]?.fields["name"]?.local != nil {
                state.folders[id]?.fields["removed"]?.local = .bool(true)
            }
        }
    }
}

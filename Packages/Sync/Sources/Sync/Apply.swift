import Document
import Foundation
import InkModel
import Library

/// What merging an op changed: which notebook or folder now has something for the library.
public enum ApplyEffect: Hashable, Sendable {
    case none
    case notebook(NotebookID)
    case folder(FolderID)
}

/// The merge (#225), pure: one op into the state. Idempotent and order-independent for ops of different
/// stamps, so re-reading a log is safe and devices that applied the same ops agree.
///
/// - Per notebook field, per folder field and per page: the op wins iff its stamp is later.
/// - A remote `pageSet` that wins over the version this device shows, written without seeing it (`base` isn't
///   that version's clock), with ink on both sides, marks the shown blob ``PageRecord/replaced``: the library
///   writes then record a ``Conflict`` (the ink stays recoverable with Keep mine).
/// - `notebookDelete` is a tombstone: it wins over every older op; a later op brings the notebook back, at
///   the root and out of the trash (``NotebookRecord/effective(_:)``).
/// - Lamport: the state's clock becomes at least the op's.
enum Apply {
    static func apply(_ op: SyncOp, from device: String, to state: inout SyncState) -> ApplyEffect {
        state.clock = max(state.clock, op.clock)
        let stamp = Stamp(clock: op.clock, device: device)
        let remote = device != state.deviceId
        switch op.change {
        case let .folderSet(id, fields):
            var record = state.folders[id] ?? FolderRecord()
            var changed = false
            for (key, value) in fields where key == "name" || key == "parent" {
                changed = set(&record.fields[key], value, at: stamp) || changed
            }
            if let removed = record.fields["removed"], removed.stamp < stamp {
                changed = set(&record.fields["removed"], .bool(false), at: stamp) || changed
            }
            state.folders[id] = record
            return changed ? .folder(id) : .none
        case let .folderRemove(id):
            var record = state.folders[id] ?? FolderRecord()
            let changed = set(&record.fields["removed"], .bool(true), at: stamp)
            state.folders[id] = record
            return changed ? .folder(id) : .none
        case .unknown:
            return .none
        default:
            break
        }
        guard let id = op.change.notebook else { return .none }
        var record = state.notebooks[id] ?? NotebookRecord()
        let changed = apply(op.change, stamp: stamp, remote: remote, to: &record)
        if changed, remote {
            record.from.insert(device)
            record.modifiedAt = max(record.modifiedAt ?? .distantPast, op.at)
        }
        state.notebooks[id] = record
        return changed ? .notebook(id) : .none
    }

    private static func apply(_ change: SyncChange, stamp: Stamp, remote: Bool, to record: inout NotebookRecord) -> Bool {
        switch change {
        case let .notebookSet(_, fields):
            var changed = false
            for (key, value) in fields where NotebookField(rawValue: key).map({ $0 != .trashed }) ?? false {
                changed = set(&record.fields[key], value, at: stamp) || changed
            }
            return changed
        case .pageSet:
            return setPage(change, stamp: stamp, remote: remote, in: &record)
        case let .pageRemove(_, page):
            let current = record.pages[page]
            if let current, current.stamp >= stamp {
                return false
            }
            record.pages[page] = PageRecord(
                stamp: stamp, base: current?.stamp.clock ?? 0, blob: nil, meta: current?.meta ?? PageMeta(template: .blank),
                removed: true, local: current?.local, replaced: nil
            )
            return true
        case let .coverSet(_, blob):
            if let cover = record.cover, cover.stamp >= stamp {
                return false
            }
            record.cover = CoverRecord(stamp: stamp, blob: blob, localStamp: record.cover?.localStamp, local: record.cover?.local)
            return true
        case let .assetAdd(_, asset):
            return record.assets.insert(asset).inserted
        case let .lifecycle(_, lifecycle):
            return apply(lifecycle, stamp: stamp, to: &record)
        case .folderSet, .folderRemove, .unknown:
            return false
        }
    }

    private static func setPage(_ change: SyncChange, stamp: Stamp, remote: Bool, in record: inout NotebookRecord) -> Bool {
        guard case let .pageSet(_, page, base, entry, strokes) = change else { return false }
        let current = record.pages[page]
        if let current, current.stamp >= stamp {
            return false
        }
        var replaced = remote ? current?.replaced : nil
        if remote, let current, !current.removed, base != current.stamp.clock, current.blob != nil, strokes != nil,
           current.local?.stamp == current.stamp
        {
            replaced = current.blob
        }
        record.pages[page] = PageRecord(
            stamp: stamp, base: base, blob: strokes, meta: entry, removed: false, local: current?.local, replaced: replaced
        )
        return true
    }

    private static func apply(_ lifecycle: SyncChange.Lifecycle, stamp: Stamp, to record: inout NotebookRecord) -> Bool {
        switch lifecycle {
        case .trash:
            return set(&record[.trashed], .bool(true), at: stamp)
        case .restore:
            return set(&record[.trashed], .bool(false), at: stamp)
        case .delete:
            if let tombstone = record.tombstone, tombstone >= stamp {
                return false
            }
            record.tombstone = stamp
            return true
        }
    }

    /// Last writer wins: sets `field` to `value` if `stamp` is later (keeping its local marker).
    private static func set(_ field: inout Field?, _ value: JSONValue, at stamp: Stamp) -> Bool {
        if let field, field.stamp >= stamp {
            return false
        }
        field = Field(stamp: stamp, value: value, local: field?.local)
        return true
    }
}

import CoreGraphics
import Foundation
import InkModel

extension Journal {
    /// What to do with the journal file after ``recover(_:identity:journal:)``.
    enum Disposition: Hashable {
        /// No journal on disk.
        case none
        /// Keep the first `length` bytes (truncate if the file is longer) and append after them.
        case keep(length: Int)
        /// Delete it: header unusable, or already folded into the stroke file.
        case discard
    }

    /// Result of replaying a journal over a freshly loaded page.
    struct Recovery {
        /// The page with every valid record applied.
        var page: Page
        /// Journal header when kept (the base for further appends).
        var header: Header?
        var disposition: Disposition
        /// Records applied.
        var replayed: Int
        /// Why replay stopped short of end of file, if it did.
        var damage: Damage?
        /// The journal is stale: a checkpoint already wrote its edits into the stroke file.
        var stale: Bool
        /// Whether the page differs from what the manifest + stroke file say (needs a checkpoint).
        var isDirty: Bool
    }

    /// Replays `journal` (the `.wal` bytes, `nil` if absent) over `page`, which was loaded from a stroke
    /// file with `identity`. Pure: no I/O. Idempotent: the same inputs give the same page.
    static func recover(_ page: Page, identity: StrokesIdentity, journal: Data?) throws(DocumentError) -> Recovery {
        guard let journal else {
            return Recovery(page: page, disposition: .none, replayed: 0, stale: false, isDirty: false)
        }
        let scan = try scan(journal)
        guard let header = scan.header else {
            return Recovery(page: page, disposition: .discard, replayed: 0, damage: scan.damage, stale: false, isDirty: false)
        }
        guard header.base == identity else {
            // A checkpoint wrote the stroke file but crashed before deleting the journal. The manifest
            // may still hold the older rev; adopt the journal's last one so revs never go backwards.
            let rev = max(page.rev, scan.records.last?.rev ?? header.baseRev)
            let adopted = Page(id: page.id, template: page.template, strokes: page.strokes, images: page.images, rev: rev)
            return Recovery(page: adopted, disposition: .discard, replayed: 0, stale: true, isDirty: rev != page.rev)
        }
        var current = page
        var replayed = 0
        var damage = scan.damage
        var length = headerLength
        for (record, end) in zip(scan.records, scan.recordEnds) {
            do {
                try current.apply(record.edit)
            } catch {
                damage = Damage(kind: .invalidRecord, offset: length)
                break
            }
            current = Page(id: current.id, template: current.template, strokes: current.strokes, images: current.images, rev: record.rev)
            replayed += 1
            length = end
        }
        return Recovery(
            page: current, header: header, disposition: .keep(length: length), replayed: replayed,
            damage: damage, stale: false, isDirty: replayed > 0
        )
    }
}

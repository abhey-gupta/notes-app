import InkModel
import PencilKit
import UIKit

/// The canvases' PencilKit strokes, converted once per stroke and page. Converting is ~25 µs a stroke
/// (`PencilKitConversion.pkStroke`), ~10 ms for a full page: on main that drops frames when a page arrives
/// mid-animation (the library → editor zoom), so a loaded page is converted off main first
/// (``PencilKitInkEngine/prepare(_:)``) and rebuilds (erase, undo, selection) reuse the conversions.
///
/// An entry is valid while its stroke is unchanged (same value; equal strokes from one page share their
/// sample buffers, so the check is cheap) and colors are: a theme or palette change empties the cache.
@MainActor
final class PKStrokeCache {
    private struct Entry {
        let stroke: Stroke
        let pk: PKStroke
    }

    private var pages: [PageID: [StrokeID: Entry]] = [:]
    /// Bumps when the cache empties: a conversion started before then is stale.
    private(set) var generation = 0
    /// Strokes converted on main so far (tests check a prepared page needs none).
    private(set) var mainConversions = 0

    /// `strokes` of `page` as PencilKit strokes; converts misses with `convert`. The page keeps only these.
    func pkStrokes(_ strokes: [Stroke], on page: PageID, convert: (Stroke) -> PKStroke) -> [PKStroke] {
        let cached = pages[page] ?? [:]
        var kept: [StrokeID: Entry] = [:]
        kept.reserveCapacity(strokes.count)
        let pks = strokes.map { stroke in
            if let entry = cached[stroke.id], entry.stroke == stroke {
                kept[stroke.id] = entry
                return entry.pk
            }
            mainConversions += 1
            let pk = convert(stroke)
            kept[stroke.id] = Entry(stroke: stroke, pk: pk)
            return pk
        }
        pages[page] = kept
        return pks
    }

    /// Adds conversions made off main under `generation`; dropped if the cache emptied since.
    func insert(_ strokes: [Stroke], _ pks: [PKStroke], on page: PageID, generation: Int) {
        guard generation == self.generation else { return }
        var entries = pages[page] ?? [:]
        for (stroke, pk) in zip(strokes, pks) {
            entries[stroke.id] = Entry(stroke: stroke, pk: pk)
        }
        pages[page] = entries
    }

    /// Drops pages not in `ids`.
    func retain(_ ids: some Collection<PageID>) {
        let keep = Set(ids)
        pages = pages.filter { keep.contains($0.key) }
    }

    /// Colors changed: every conversion is stale.
    func removeAll() {
        pages = [:]
        generation += 1
    }
}

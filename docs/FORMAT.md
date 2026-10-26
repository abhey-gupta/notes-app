# Notebook format

On-disk layout of a Notespace notebook and what we promise about it. Details: ARCHITECTURE.md §4.2–4.5; byte layouts in the doc comments of `Document.StrokeCodec`, `Document.Journal`, `Document.Manifest`.

## Where

- `Documents/Notebooks/<notebookID>.nb/`: one directory package per notebook (UTType `com.abhey.notespace.notebook`, conforms to `com.apple.package`). Named by ID, never by title.
- `Application Support/Library/index.json`: library index (titles, folders, recents). A cache: rebuilt from the packages if missing or damaged.
- `Application Support/Library/Trash/<notebookID>.nb`: deleted notebooks, purged after 30 days.

## Package

```
<notebookID>.nb/
  manifest.json          formatVersion, notebook fields, pages[] in page order (JSON, sorted keys, dates as Unix ms)
  pages/<pageID>.strokes binary stroke file ("INKS"); absent until the page has ink
  pages/<pageID>.wal     append-only edit journal ("INKW"); exists only between autosave checkpoints
  thumbs/<pageID>.heic   page thumbnail
  thumbs/cover.heic      library cover
  backup-v<N>/           manifest.json + pages/ as they were before the v<N> → v<N+1> migration
```

| File | Version field | Current |
|---|---|---|
| `manifest.json` | `formatVersion` | 2 |
| `*.strokes` | u16 after `INKS` | 2 |
| `*.wal` | u16 after `INKW` | 2 |

`pageSize` is the original page; `pageExtension: {left, right}` (points, written only once pages were widened, #129) is paper added beside every page. Stroke coordinates start at the widened page's left edge. Absent = not widened, so older packages read unchanged.

Stroke files and journals are little-endian, CRC-32 checked; damage is a typed error, never garbage ink. Thumbnails and the index are derived data: safe to delete.

## Identity

- Every notebook, page and stroke has a UUIDv7 ID (time-ordered). Files are named by ID.
- Notebook and each page carry a `rev` counter, bumped on every autosave checkpoint.
- No file paths are stored anywhere; IDs only. Moving or renaming a package changes nothing inside it.
- Edits are an append-only journal of `PageEdit`s: the unit sync will ship later.

## Stability promise

- **Old notebooks always open.** Every older `formatVersion` this app ever wrote is migrated on open (`Document/Migrations`), after copying the old files to `backup-v<N>/`. Migration is crash-safe and idempotent: until the manifest says the new version, the next open redoes it.
- **Newer notebooks never get damaged.** A `formatVersion` above the build's own is refused with a calm "made by a newer version" message. Nothing is written.
- **Unknown JSON keys survive.** Keys this build doesn't know, at notebook or page level, are preserved round-trip.
- **Bump on incompatible change only.** Additive JSON keys don't bump `formatVersion`; any change to a binary layout or to the meaning of a field does, with a migration step and a test that opens a hand-built package of the previous version.

## History

- **v1**: initial format.
- **v2** (#71): stroke files and journals gain the PencilKit rendering block (per-point size and opacity, ink, seed), so strokes redraw exactly as captured. v1 strokes render from the pen profile.

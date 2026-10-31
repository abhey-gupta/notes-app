# Notebook format

On-disk layout of a Notespace notebook and what we promise about it. Details: ARCHITECTURE.md §4.2–4.5; byte layouts in the doc comments of `Document.StrokeCodec`, `Document.Journal`, `Document.Manifest`.

## Where

- `Documents/Notebooks/<notebookID>.nb/`: one directory package per notebook (UTType `com.abhey.notespace.notebook`, conforms to `com.apple.package`). Named by ID, never by title.
- `Application Support/Library/index.json`: library index (titles, folders, recents). A cache: rebuilt from the packages if missing or damaged.
- `Application Support/Library/Trash/<notebookID>.nb`: deleted notebooks, purged after 30 days.
- `Application Support/Library/backup-state.json`: what the last backup copied (#174): the folder's path, last backup time, and per notebook its location (`notebooks`/`trash`), manifest modification date, `rev`, page `rev`s of copied stroke files, copied assets, cover date and size, bytes. Derived: missing, damaged or about another folder means the next backup copies everything again.

- `Application Support/Library/sync-state.json`: what this device knows of the sync folder (#225): `formatVersion`, `folder` (path), `deviceId`, Lamport `clock`, `nextSeq`, `applied` (device → last seq read), `notebooks` (per notebook: `fields` {name: {stamp, value, local}}, `pages` {pageId: {stamp, base, blob, meta, removed, local {stamp, rev, blob}, replaced}}, `cover` {stamp, blob, localStamp, local}, `assets`, `localAssets`, `tombstone`, `materialised`, `localRev`, `modifiedAt`, `from`), `folders` {id: {fields: name, parent, removed}}, `deferred` (notebooks waiting for their editor to close), `conflicts` [{notebook, page, theirs, mine, device, since}], `garbage` {path: {since, acks}}. A stamp is `{clock, device}`; `local` is the value the library held at the last pull or push. Derived: missing, damaged, newer, or about another folder or device ID means the next pull re-reads every log and the next push re-sends the whole library.

## Sync folder (#225)

```
<picked folder>/
  sync.json                                   formatVersion 1, created. No sync.json: nothing in the folder is read
                                              (a #174 backup folder's files are left alone)
  devices/<deviceId>.json                     id, name, model, lastSeen, clock, applied {deviceId: seq} (the acks GC waits for)
  log/<deviceId>/<seq, 10 digits>.json        {seq, device, writtenAt, ops: [op]}: append-only, written once
  log/<deviceId>/snapshot.json                same shape: the device's ops folded (latest per field/page/cover…), seq = last folded
  blobs/<notebookId>/pages/<pageId>/<clock 12 digits>-<deviceId>.strokes   stroke file, written once
  blobs/<notebookId>/cover/<clock 12 digits>-<deviceId>.heic                cover, written once
  blobs/<notebookId>/images/<name>            package assets by their package name (unique), written once
  blobs/<notebookId>/backgrounds/<name>
```

- Each device writes only under its own names, and every file but `devices/<me>.json` and `snapshot.json` is written once: providers never see two devices write one file, readers never see half of one (temp file + rename, coordinated).
- An op is `{"op": <kind>, "clock": <Lamport>, "at": <ms>, …}`: `notebookSet` {notebook, fields} (fields: `title`, `folder`, `cover`, `paper`, `theme`, `keepsExactColors`, `pageSize`, `leftExtension`, `createdAt`, `extra`, `pages` = page order) · `pageSet` {notebook, page, base, entry {template, background?, extra}, strokes?} · `pageRemove` {notebook, page} · `coverSet` {notebook, blob} · `assetAdd` {notebook, kind `images`/`backgrounds`, name} · `notebookTrash` / `notebookRestore` / `notebookDelete` {notebook} · `folderSet` {folder, fields: `name`, `parent`} · `folderRemove` {folder}. Unknown kinds are skipped. Dates are Unix ms, keys sorted.
- Merge: per field and per page, the later stamp (clock, then device ID) wins. A `pageSet` whose `base` isn't the clock of the version the reader shows, with ink on both sides, records a conflict; the replaced blob stays for Keep mine. `notebookDelete` is a tombstone, sent only for a notebook last seen in the trash (every purge goes through it; a live notebook that is suddenly missing locally is never sent as a delete): a later op brings the notebook back, at the root.
- Order: blobs first, then the log entry that names them, then `devices/<me>.json`. A reader that sees an entry before its blobs keeps the notebook as it was and retries; a gap in a device's seqs stops that device until the missing entry arrives.
- GC: a device deletes its own blobs 30 days after they stopped being referenced, once every device seen in the last 90 days has read past the op that replaced them; it folds its log into `snapshot.json` and deletes the entries those devices have read.

## Backup folder (#174)

```
<picked folder>/
  library.json           formatVersion 1, folders, notebooks (id, title, folderID, cover, paper, theme, pageCount, pageSize,
                         modifiedAt, rev, trashed), device, writtenAt (pretty JSON, sorted keys, dates as Unix ms)
  Notebooks/<id>.nb/     manifest.json, pages/*.strokes, images/*, backgrounds/*, thumbs/cover.heic (no journals, no page thumbnails)
  Trash/<id>.nb/         deleted notebooks, same contents, removed with the local purge
```

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
- **v2, additive** (#129): `manifest.json` may carry `leftExtension` (points of paper added left of the original page; absent = 0). `pageSize.width` grows with the paper added either side. Strokes are stored in page space from the widened paper's top-left, so a left extension shifts their x.

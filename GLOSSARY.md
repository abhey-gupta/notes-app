# Notespace

A handwriting notebook app for iPad. These are the words for what a user's notebook is made of and how changes to it happen.

## Notebook content

**Notebook**:
One document the user writes in: an ordered list of pages plus its title, cover and paper.
_Avoid_: Document, file, note

**Page**:
One sheet of paper in a notebook, with a template and the strokes on it.
_Avoid_: Sheet, canvas

**Stroke**:
One continuous mark made with a pen or highlighter, from pen-down to pen-up.
_Avoid_: Line, path, drawing

**Template**:
The printed pattern on a page (blank, lined, dotted, grid, Cornell).
_Avoid_: Background, paper pattern

**Photo**:
A picture placed on a page beneath all its strokes, at a frame in page points. Its bytes are an asset the notebook keeps once; copies of a photo share the asset.
_Avoid_: Image (for the placement), attachment, sticker

**Photo flyout**:
The grid of recent photos the toolbar's Photo button opens; one tap places that photo on the current page, selected.
_Avoid_: Picker, gallery, media browser

**Page extension**:
Paper added beside the original page width, on the left and/or the right; every page of a notebook shares it. A side grab (press-hold at a page edge, drag) changes it.
_Avoid_: Margin, canvas size, landscape

## Sync

**Sync**:
Keeping the library the same on every device that uses one sync folder: each device sends what changed on it and takes in what changed elsewhere.
_Avoid_: Backup, replication, mirror

**Sync folder**:
The folder in Files every device picked for sync (iCloud Drive, Google Drive, Dropbox…). It holds each device's log and the blobs its ops name; it is also the backup: a fresh device adopts it.
_Avoid_: Backup folder, remote, server, cloud

**Op**:
One change a device sends: a notebook's fields, one page's content, a page removed, a cover, an asset, trash/restore/delete, a folder's fields or removal. A push writes its ops as one log entry.
_Avoid_: Event, mutation, change set

**Clock**:
The Lamport number every op carries: one more than the largest the device has seen. Of two changes to the same field or page, the later clock wins (equal clocks: the larger device ID).
_Avoid_: Timestamp, version, rev (that is the notebook's own counter)

**Blob**:
A file in the sync folder an op refers to by name (a page's strokes, a cover, a photo, a PDF). Written once, never changed; named by its clock and device so no two devices write the same one.
_Avoid_: Attachment, upload

**Tombstone**:
The op a device sends when a deleted notebook leaves its trash for good. It wins over everything older; a later change brings the notebook back, outside any folder.
_Avoid_: Purge (for the op), hard delete

**Adopt**:
A device with an empty library taking in everything the sync folder holds, with its folders, without the user picking notebooks. Replaces #174's Restore.
_Avoid_: Restore, import, download

**Deferred**:
Changes from another device to a notebook open in an editor: kept until the editor closes, then written. Folder and trash changes apply at once.
_Avoid_: Queued, pending (for the concept)

**Conflict**:
The same page changed on two devices before either saw the other's change: the later version is shown, and the replaced ink can come back with Keep mine.
_Avoid_: Merge, collision

**Keep mine**:
The pill's button on a page in conflict: the page shows this device's replaced version again at once and every device takes it (sent as a new op with a later clock). One undo step. The pill goes on its own after 30 s or with ×, and the replaced version with it.
_Avoid_: Restore, revert, resolve

**Ghost ink**:
A page's replaced version drawn faintly under its ink while it is in conflict: dashed lines in the selection blue, never touched, never saved, rendered or exported. Goes with Keep mine, × or the 30 s.
_Avoid_: Overlay, diff, shadow strokes

## Changes

**Page edit**:
One change to the strokes or photos on one page (add, remove, replace, move/resize, recolor). Every page edit can be inverted exactly.
_Avoid_: Mutation, operation, change set

**Page structure edit**:
Inserting, deleting or moving a whole page.
_Avoid_: Page operation

**Edit pipeline**:
The single ordered path every change to an open notebook takes: saved first, then shown, then added to the history. Changes take effect in the order the user made them.
_Avoid_: Edit queue, session, editor

**History**:
The notebook's undo/redo list. One entry is one user-visible undo step, which may hold several page edits (a long eraser scrub) or page structure edits.
_Avoid_: Undo stack, edit log

**Gesture**:
Everything from the first touch down to the last touch lifted. An eraser gesture is one undo step however many pages it crosses.
_Avoid_: Scrub, session

**Page mirror**:
The copy of the loaded pages the screen draws from; it follows the saved notebook, never leads it.
_Avoid_: Cache, residency (for the concept)

**Echo**:
A saved change coming back to the screen, so what is drawn always matches what is saved.
_Avoid_: Callback, refresh

## Selection

**Selection**:
The strokes and photos the lasso picked on one page (or a photo just placed), outlined with handles and the context bar. At most one at a time; any new gesture, tool change, undo/redo or tap outside ends it.
_Avoid_: Lasso (for the result), marquee

**Lifted ink**:
Selected strokes drawn off the page while they are dragged, put back once the move or resize is saved.
_Avoid_: Drag preview (for the concept), ghost

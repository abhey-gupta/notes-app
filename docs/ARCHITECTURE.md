# Architecture

Day 0 architecture for **Notespace**. `docs/SCOPE.md` is the authoritative scope and perf budget; this doc says how we hit it. Issues reference sections by number (e.g. "§3").

Targets: **iPadOS 26 minimum** (deployment target 26.0), built with Xcode 27.1 / iOS 27.1 SDK / Swift 6.4, Swift 6 strict concurrency, SwiftUI app shell with UIKit/Metal where latency matters. Zero third-party runtime dependencies on Day 0.

## 1. Principles

1. **Budgets are features.** Every PR that touches launch, open, ink, or scroll runs the perf tests (§12). Regressions block merge.
2. **Own the ink.** The document model, file format, and rendering are ours. Apple frameworks are used for input delivery, scrolling physics, PDF, and chrome, not for the data.
3. **Main thread draws, everything else works elsewhere.** Tile rendering, thumbnails, saving, indexing, export all run off main.
4. **No spinners.** Every async load has a synchronous placeholder already on disk (thumbnail, index snapshot). The user never sees nothing.
5. **Pure Swift first.** Model, geometry, codec, tools logic are UIKit-free packages that test headlessly with `swift test`.
6. **Liquid Glass chrome.** All floating UI (toolbars, popovers, pills, sheets) uses native iOS 26 Liquid Glass; paper and ink never do. Glass floats over content, content never sits on glass.

## 2. Module layout

Xcodegen project (`project.yml`), one app target, local Swift packages under `Packages/`. Each package has its own tests.

```
notes-app/
  project.yml                 xcodegen; app target + test targets only
  App/                        Notespace (SwiftUI) – thin shell, wiring, screens
  Packages/
    InkModel/                 Stroke, Sample, Page, Notebook, PageEdit, InkColor (pure Swift, Sendable)
    InkGeometry/              smoothing, outline tessellation, hit-testing, spatial index (pure Swift)
    InkEngine/                InkEngine protocol + shared input pipeline types (UIKit, no Metal)
    InkEngineMetal/           Metal renderer, tile cache, shaders (.metal)
    InkEnginePencilKit/       PKCanvasView adapter – spike baseline / fallback
    Tools/                    tool state machine, eraser, lasso, undo stack (depends InkModel, InkGeometry)
    Canvas/                   page layout, virtualization, scroll/zoom host, thumbnails (UIKit)
    Document/                 package format, codec, WAL autosave, migrations (Foundation only)
    Library/                  index store, search, folders (Foundation only)
    Export/                   PDF renderer (CoreGraphics)
    DesignSystem/             tokens, glass capsule, typography, themes (SwiftUI)
    Perf/                     signposts, MetricKit, debug HUD
  Tests/
    PerfTests/                XCTest perf metrics + baselines (runs on simulator in CI, device by hand)
    UITests/                  smoke: launch, create notebook, open, export
  Fixtures/                   generated 1/10/100/300-page notebooks for perf + dev
  docs/  design/
```

Dependency direction (arrows = imports). Nothing below imports anything above.

```
App
 ├─ Canvas ─────┬─ InkEngineMetal ─┐
 ├─ Tools       ├─ InkEnginePencilKit ├─ InkEngine ─┐
 ├─ Library     │                    │             ├─ InkGeometry ─ InkModel
 ├─ Export ─────┤                    │             │
 ├─ Document ───┘                    └─────────────┘
 ├─ DesignSystem
 └─ Perf
```

Headless-testable with `swift test` on macOS: `InkModel`, `InkGeometry`, `Document`, `Library`, `Tools`, `Export` (CoreGraphics is available on macOS). Simulator-only: `InkEngine*`, `Canvas`, `DesignSystem`, App.

Concurrency: value types everywhere in `InkModel` (`Sendable` structs). UIKit/Metal view classes are `@MainActor`. Background work lives in actors (`DocumentStore`, `LibraryStore`, `ThumbnailService`, `TileRenderer`). No `@unchecked Sendable` without a comment explaining why.

## 3. Ink engine: custom Metal, PencilKit as spike baseline and fallback

**Decision: build our own Metal ink engine. Keep a PencilKit adapter behind the same seam for the latency spike and as a fallback if the Metal engine slips.**

Why not PencilKit as the shipping engine:

- **Multi-page continuous scroll at 120 Hz on 100+ pages.** `PKCanvasView` is itself a `UIScrollView` and its low-latency path assumes it owns the viewport. Options are one giant canvas per notebook (unbounded memory, no per-page files, no page virtualization) or one canvas per page nested in our scroll view (nested scroll views, zoom sync, tool state replication). Neither meets the scroll budget cleanly.
- **Tools in scope are not exposed.** Lasso resize and recolor, partial-eraser geometry, three custom pen profiles, highlighter under-ink layering. We would implement all of these on top of `PKDrawing.strokes` anyway, which means we already own the model and the hard parts.
- **Rendering control.** Night paper ink adaptation (§10), vector PDF export (§9), future PDF-import compositing all want one renderer that draws page background + ink in a single pass.
- **Latency parity is achievable.** PencilKit's latency comes from public tech: coalesced + predicted touches, direct Metal presentation, 120 Hz. Procreate/Goodnotes/Notability all ship custom engines at the hardware floor.

Why keep PencilKit around:

- It is the **known-good latency baseline**. The spike (#16) measures ours against it on device; we ship Metal only if it is within one frame (8.3 ms) of PencilKit for pen-down-to-pixel.
- The adapter is cheap (~2 days) and doubles as the fallback if the Metal engine isn't at parity by end of week 3.

Cost: the Metal engine is the single biggest engineering risk (§14). Mitigation is the spike plus the seam.

### 3.1 The seam

`InkEngine` is a UIKit-hosted view plus a small command surface. The canvas host (§5) owns scrolling, zooming, and page layout; the engine only draws and captures ink for the pages it's told about.

```swift
// Packages/InkEngine
@MainActor public protocol InkEngine: AnyObject {
    var view: UIView { get }                          // sized to the viewport, not the content
    var delegate: InkEngineDelegate? { get set }

    func setViewport(_ v: Viewport)                   // content offset + zoom + visible page frames
    func setPages(_ pages: [PageSnapshot])            // immutable stroke snapshots for visible pages
    func setTool(_ tool: ToolConfiguration)
    func setTheme(_ theme: PaperTheme)
    func apply(_ edit: PageEdit, to page: PageID)     // undo/redo/lasso go through here
    func invalidate(_ rect: CGRect, in page: PageID)
    func render(page: PageSnapshot, size: CGSize, scale: CGFloat) async -> CGImage  // thumbnails, export raster fallback
}

public protocol InkEngineDelegate: AnyObject {
    func engine(_ e: InkEngine, didCommit stroke: Stroke, to page: PageID)
    func engine(_ e: InkEngine, didReceiveEraser samples: [Sample], to page: PageID)  // Tools package resolves what gets erased
    func engine(_ e: InkEngine, didReceiveLasso path: [CGPoint], to page: PageID)
    func engineDidBeginStroke(_ e: InkEngine)         // focus-mode chrome collapse
}
```

Rules: the engine never mutates the document. It emits committed strokes/eraser/lasso input; `Tools` turns them into `PageEdit`s; `DocumentStore` applies them and calls back `apply`/`invalidate`. One direction, one source of truth.

PencilKit adapter strategy: a `PKCanvasView` for the *active* page only (the one under the Pencil), overlaid on the canvas host; non-active pages are rendered as images. Enough for the spike and a fallback, not pretty.

### 3.2 Input pipeline (shared by both engines)

- `UIView.touchesBegan/Moved/Ended` on the engine view. For each event: `event.coalescedTouches(for:)` appended to the live stroke, `event.predictedTouches(for:)` rendered as a discardable tail that is replaced next event.
- `touchesEstimatedPropertiesUpdated` patches pressure/azimuth/altitude in place by `estimationUpdateIndex`. Samples carry `force`, `altitude`, `azimuth`, `timestamp`, and the raw `location` in page space.
- Pencil-only drawing when a Pencil has been seen this session (`touch.type == .pencil`); `.direct` touches scroll/zoom. Setting: "Draw with finger" off by default.
- **Palm rejection**: UIKit already suppresses most palm contacts when a Pencil is in use. On top: ignore `.direct` touches that begin while a `.pencil` touch is active or within 150 ms after one ends; treat `.direct` touches with `majorRadius` above a threshold as palm. Never draw with a finger while Pencil is active.
- **Pencil interactions**: `UIPencilInteraction` for double-tap (iOS 12.1+) and squeeze (iOS 17.5+, `didReceiveSqueeze`). Honor `UIPencilInteraction.preferredTapAction` / `preferredSqueezeAction` system settings; our default mapping is "switch to eraser, switch back on next double-tap". **Hover** via `UIHoverGestureRecognizer` (Pencil 2 on M2+ iPads, iOS 16.1+; `zOffset`, `altitudeAngle`, `azimuthAngle`): show tool cursor preview of width/color.

### 3.3 Rendering pipeline (Metal)

- `CAMetalLayer` in the engine view, `framebufferOnly = true`, `maximumDrawableCount = 2` (lower latency than triple buffering), `displaySyncEnabled = true`. `CADisplayLink` with `preferredFrameRateRange(min: 120, max: 120, preferred: 120)` during ink and scroll; idle when nothing changes.
- **Live stroke** is drawn directly to the drawable each touch event (not on the display link) on top of cached tiles. Predicted tail drawn, then discarded. On pen-up the stroke is committed: delegate callback, tile invalidation of the stroke's bounds, next tile render includes it.
- **Stroke geometry** (`InkGeometry`, pure Swift, headless-tested): raw samples → Catmull-Rom centerline resampled at ~1 pt → per-point width from pen profile → triangle-strip outline with a signed-distance coverage in the fragment shader for AA. No MSAA.
- **Pen profiles** (`PenProfile`): `fountain` (width = base × f(pressure) × g(velocity), ink-like thick/thin), `ballpoint` (near-constant width, slight pressure, slight grain), `brush` (pressure + tilt widen, soft edge via wider SDF falloff). `highlighter`: constant width, flat chisel caps, 40% alpha, multiply blend, **always rendered beneath pen strokes** regardless of z-order (two draw passes per tile: highlighter, then ink).
- **Page background** (templates §5.3) is procedural in the shader: blank/lined/dotted/grid/Cornell from page size + theme. Resolution-independent, no texture.
- Colors are resolved at render time from `InkColor` (§10). Night paper swaps the palette, not the data.

Latency measurement: timestamp of the touch (`UITouch.timestamp`) vs `MTLDrawable.presentedTime` via `addPresentedHandler`; report p50/p95 in the debug HUD and signposts. Hardware floor target: ≤ PencilKit + 1 frame on the same device.

## 4. Document model and file format

### 4.1 Model (`InkModel`)

```swift
struct Notebook { id: NotebookID; title; cover: CoverColor; paper: PaperStyle; theme: PaperTheme; keepsExactColors: Bool; pageSize: CGSize; pages: [PageID]; createdAt; modifiedAt; rev: UInt64 }
struct Page     { id: PageID; template: PageTemplate; strokes: [Stroke]; rev: UInt64 }
struct Stroke   { id: StrokeID (UUIDv7); tool: PenKind; color: InkColor; width: Float; samples: [Sample]; bounds: CGRect }
struct Sample   { x, y: Float; force: Float /* 0...1 */; altitude: Float; azimuth: Float; t: Float /* s since stroke start */ }
enum   PageEdit { add([PlacedStroke]); remove([PlacedStroke]); replace(old: [PlacedStroke], new: [PlacedStroke]); transform([StrokeID], forward: CGAffineTransform, backward: CGAffineTransform); recolor([ColorChange]) }
// PlacedStroke = (z-index, Stroke); ColorChange = (id, from, to). Build via Page.addEdit/removeEdit/replaceEdit/transformEdit/recolorEdit.
```

Strokes store **raw samples, not outlines**, so improving the tessellation later re-renders old notes better. `PageEdit` is the one edit vocabulary used by tools, undo/redo, autosave journal, and (later) sync. Every `PageEdit` carries the prior state its undo needs (removed strokes with z-index, prior colors, inverse matrix), so `inverse()` is pure and `e.inverse().inverse() == e`.

### 4.2 On-disk format: notebook package

A notebook is a directory package, exported UTType `com.abhey.notespace.notebook` conforming to `com.apple.package`, extension `.nb`. (`.nb` is also Mathematica's extension; harmless on Day 0 since notebooks live in our container, but revisit before exposing in Files.) Lives in `Documents/Notebooks/` (file-provider visible later; not Day 0).

```
<notebookID>.nb/        named by ID, never by title: renames don't move files
  manifest.json          formatVersion, notebook fields above, `pages` array of page entries (id, template, rev,
                         reserved background) in page order; sorted keys, dates as Unix ms
  pages/
    <pageID>.strokes     binary stroke file (§4.3); absent until the page has ink
    <pageID>.wal         append-only edit journal, exists only between autosave checkpoints (§4.4)
  thumbs/
    <pageID>.heic        page thumbnail, 176×228 pt @2x
    cover.heic           first page at 344×196 pt @2x for library "recents"
```

Per-page files are deliberate: page-scoped loads (open page 1 without reading page 90), page-scoped autosave, page-scoped sync conflicts later.

`Document.NotebookPackage` owns this layout: create (staged in a hidden sibling dir, then renamed into place), open (manifest only), `loadPage` (one stroke file), `savePages` (stroke files, then one manifest write), insert/delete/move page. Every file write is temp + `rename`. Manifest page order is the `pages` array itself (no separate `pageOrder`).

### 4.3 Stroke codec (`Document`)

Custom little-endian binary, no schema library:

```
header: magic "INKS" | u16 formatVersion | u32 strokeCount | u32 flags (bit0: lz4) | u32 bodyLength (uncompressed) | u32 crc32
stroke: u128 id | u8 tool | InkColor (u8 kind + 4 B: semantic slot,0,0,0 or r,g,b,a) | f32 width | u32 sampleCount | samples[f32 x,y,force,altitude,azimuth,t]
```

Whole body after header compressed with `Compression` framework lz4 (`COMPRESSION_LZ4`), kept only if smaller. `bodyLength` sizes the decode buffer; CRC-32 covers the header and stored body, so damage is a typed error, never garbage ink. Decoder validates every length before reading and never traps (fuzzed). Measured (M-series, release): 400 × 60-sample page decodes in ~0.4 ms; 100-page notebook manifest + page 1 in ~0.9 ms. Raw Float32 samples barely compress (~2 %); quantize/delta-code later only if size matters.

### 4.4 Autosave and crash safety

- Every committed `PageEdit` is appended synchronously-cheap to `pages/<id>.wal` (one record, O(edit size)) from the `DocumentStore` actor. Pen-up to durable: < 50 ms, never on main.
- Checkpoint: after 2 s idle, on page leave, on background/resign-active, or when WAL > 1 MB: rewrite `<id>.strokes` to a temp file, `rename` atomically, delete WAL. Manifest written atomically (`Data.write(.atomic)`) with bumped `rev`s.
- Open: if a `.wal` exists, replay it over `.strokes` before presenting. Replay is idempotent (edits reference stroke IDs).
- Never a "Save" button. Never a dirty-state dialog.

### 4.5 Versioning, migration, forward-compat

- `formatVersion` in `manifest.json` and in each stroke file header. Integer, bumped on any incompatible change. `Document/Migrations/` holds `V1→V2` steps run on open, writing a backup `manifest.v1.json` once.
- Open refuses newer `formatVersion` with a clear message (not a crash).
- Unknown JSON keys are preserved round-trip (`extra: [String: JSONValue]` on `Manifest` and `PageEntry`).
- **Sync-ready without sync**: every entity has a stable ID (UUIDv7, time-ordered); per-notebook and per-page `rev` counters; edits are already an append-only journal of `PageEdit`s. Adding iCloud later means shipping the journal, not changing the model. No file paths stored anywhere; IDs only.
- **PDF-import-ready**: `Page` gets an optional `background: PageBackground` later (`.template` today, `.pdf(file, pageIndex)` tomorrow); the Metal background pass becomes a texture draw. No model rewrite. The slot already exists on the manifest's `PageEntry` (omitted from JSON while `.template`).

## 5. Canvas: multi-page scroll, virtualization, tiles

### 5.1 Host

`CanvasHostView` (`Canvas`, UIKit, wrapped in `UIViewRepresentable`): a `UIScrollView` for native 120 Hz physics, rubber-banding, and pinch zoom (`minimumZoomScale 0.5`, `maximumZoomScale 4`), with a transparent content view of total notebook size. The engine's `view` is **pinned to the visible rect** (not inside the content view), so there is never a giant layer. `scrollViewDidScroll`/`DidZoom` → `engine.setViewport(...)`. Deceleration frames are drawn on the display link.

### 5.2 Page layout

`PageLayout` (pure Swift): fixed page size per notebook (A4 portrait 595×842 pt default), 24 pt gap, vertical stack. Precomputed `[pageFrame]`; visible pages by binary search. Pages have no view objects; they are just frames the engine is told about. Page indicator "3 of 11" derives from the frame whose center is nearest the viewport center.

### 5.3 Templates

`PageTemplate`: `blank | lined(spacing) | dotted(spacing) | grid(spacing) | cornell`. Rendered procedurally by the engine (§3.3). Paper styles: White `#FFFFFF`, Cream `#F6F0E1`, Night `#1B1C1F`. Editor desk behind pages: `#EDEAE4` light, `#0F1012` dark.

### 5.4 Tile cache

- `TileRenderer` (non-main, own `MTLCommandQueue`, serial queue): renders 512 px tiles per page per zoom bucket (0.5, 1, 2, 4) into an `MTLHeap`-backed texture pool. LRU by bytes, budget 256 MB on 8 GB iPads (scaled by `ProcessInfo.physicalMemory`), evict on `didReceiveMemoryWarning`.
- Residency: tiles for visible pages ± 1 page. Others evicted lazily. Stroke data for pages outside ± 3 pages is dropped from memory (reloaded from disk on demand, < 10 ms per page).
- Zoom gesture: scale existing bucket tiles on the GPU (cheap, slightly soft), then re-render at the new bucket on gesture end. No blank tiles: a missing tile falls back to the nearest bucket, then to the page thumbnail, then to flat paper.
- Invalidation is rect-based per page; a committed stroke only redraws intersecting tiles.

### 5.5 Thumbnails

`ThumbnailService` actor: debounced 1 s after the last edit on a page, and on page leave/close, renders `thumbs/<pageID>.heic` via `engine.render(...)` on the background command queue; also `cover.heic` when page 1 changes. The Library and pages overview read HEIC from disk only; never render on demand in UI.

## 6. Tools

`Tools` package, headless-tested. `ToolState` is an `@Observable` main-actor object: current tool, per-tool settings (persisted in `UserDefaults` as a Codable blob), three quick-color slots (default `#1E2129`, `#2C4FD6`, `#D2402F`).

- **Pens**: fountain / ballpoint / brush, 5 widths (3/5/8/11/15 mock units → pt widths 1.5/2.5/4/6/8), pressure toggle, 11-color palette + custom.
- **Highlighter**: 3 widths, palette subset, multiply, under-ink (§3.3).
- **Eraser**: stroke mode and partial mode, 3 widths.
  - Hit-testing uses a per-page uniform grid spatial index (`InkGeometry.StrokeIndex`, 64 pt cells) on stroke bounds, then exact outline-vs-circle test.
  - Stroke erase → `PageEdit.remove`.
  - Partial erase → split sample polyline where the eraser disk intersects, emit `PageEdit.replace(old: [id], new: [pieces])`. Pieces get new IDs. One edit per eraser gesture so undo is one step.
- **Lasso**: freeform path closed on pen-up; a stroke is selected if ≥ 50 % of its samples are inside. Selection shows a marching-ants hull with resize handles and a context bar (recolor to quick colors / palette, duplicate, delete). Move/resize → `PageEdit.transform` (samples baked, no persisted transform). Recolor → `PageEdit.recolor`.
- **Undo/redo**: our own `EditStack` (per notebook, ring of 200 `PageEdit`s with page IDs), not `UndoManager` as the store. A thin `UndoManager` bridge registers each edit so system three-finger swipe/tap and keyboard ⌘Z work. Undo coalescing: partial-eraser gesture = 1, lasso drag = 1, each stroke = 1.
- **Pencil**: double-tap/squeeze → eraser toggle (§3.2). Hover → cursor preview.

## 7. Toolbar and chrome

`ToolbarContent(axis:)` (tools, quick colors, undo/redo) is axis-agnostic SwiftUI. `ToolbarHost` makes it **dynamic** (user decision):

```swift
enum ToolbarDock: String, Codable { case top, bottom, left, right }   // left/right render vertically
```

- Default: expanded capsule floating top center (mock §02).
- Drag the toolbar → it tracks the finger, then springs to the nearest dock on release; dock persists.
- Pinch-in on the expanded toolbar → compact pill (current tool + color) at the same dock; tap the pill → expand. Focus mode reuses the compact pill.
- All transitions are `glassEffectID` morphs inside one `GlassEffectContainer` with interactive springs; Reduce Motion → crossfade. Toolbar gestures are finger-only and never reach the canvas; Pencil input is unaffected. Tracked in #26.

Chrome pieces (mock §02): left capsule (back, title, menu), center capsule (tools), right capsule (pages grid, share, more), bottom-right "3 of 11" pill. **Focus mode**: on `engineDidBeginStroke` the capsules fade to a single compact pill (mock §05) after 1.5 s of continuous inking; any tap on chrome or a scroll gesture restores. Dark mode follows system appearance; the paper theme (Night) is per-notebook and independent of system dark mode.

Glass: native Liquid Glass, verified in the iOS 27.1 SDK (all `@available(iOS 26.0, *)`): `glassEffect(_ glass: Glass = .regular, in: some Shape)`, `Glass.regular/.clear/.identity` with `.tint(_:)` and `.interactive()`, `GlassEffectContainer(spacing:)` so neighbouring capsules blend/morph, `glassEffectID(_:in:)` + `glassEffectUnion(id:namespace:)` for morph transitions (toolbar → focus pill), `.buttonStyle(.glass / .glassProminent)`. Rules: the three editor capsules live in one `GlassEffectContainer`; tool buttons use `.interactive()`; active tool tinted with the current ink color at low opacity; focus-mode collapse is a `glassEffectID` morph, not a fade; sheets/popovers use system presentation (glass by default on 26). `DesignSystem` wraps these in `GlassCapsule`/`GlassPill` so tokens stay in one place. No `Material` fallback needed (26 minimum).

## 8. Library

- `LibraryStore` actor over a single index file `Application Support/Library/index.json` (atomic writes). Entries: notebook ID, title, folder ID, cover color, modified, page count, package path relative to the Notebooks root, cover thumb path. Folders: `[Folder {id, name}]`, one level, notebook has at most one `folderID`.
- Cold launch: read index synchronously on the `LibraryStore` actor while SwiftUI builds the first frame; a 1 000-notebook index decodes in low single-digit ms. If missing or corrupt, rebuild by scanning `Documents/Notebooks/*.nb/manifest.json` (off main, library shows progressively).
- Views: Recents (last 6 by modified, with `cover.heic` previews), covers grid (all, by folder chip), folder chips (All + folders + "+"). Search field filters by title, case/diacritic-insensitive `localizedStandardContains`, in memory, no debounce needed.
- New notebook sheet (mock §06): title, cover color (8), paper (Blank/Lined/Dotted/Grid), paper style (White/Cream/Night), A4 portrait fixed. Create → write package + index entry → push editor on page 1 in the same transaction (no interim library state).
- Management: rename, move to folder, delete (trash to `Library/Trash/`, purged after 30 days), duplicate. Context menu on covers.
- Open notebook < 150 ms: index already has everything the editor needs to lay out pages (page count, page size); editor appears with page 1's thumbnail scaled up as the first frame, `DocumentStore` loads page 1's strokes (< 10 ms) and the first sharp tile replaces the thumbnail with a 120 ms crossfade. Pages 2–3 load next. Nothing else is read until scrolled near.

## 9. PDF export

`Export` package, CoreGraphics (`UIGraphicsPDFRenderer` in app, `CGContext(consumer:mediaBox:)` in headless tests). Vector by default:

- Reuse `InkGeometry` outlines → `CGPath` fill per stroke. Highlighter with `.multiply` blend, drawn first. Template background as vector lines/dots. Page size = notebook page size in points, one PDF page per notebook page.
- Brush strokes with soft edges rasterize badly as pure fill; export rasterizes brush strokes per page at 2× via `engine.render` and composites as an image under the vector ink. Everything else stays vector (small files, crisp zoom).
- Night-paper notebooks export on white paper with light-palette ink by default ("Export as shown" toggle keeps Night).
- Runs on a background task; share sheet (`UIActivityViewController` / `ShareLink` with a `FileRepresentation`) gets a temp file URL. 100 pages < 3 s on M-series. Export options: all pages / current page / range.

## 10. Theming and design tokens

`DesignSystem` is the only place hex values live. Tokens from `design/mockups-v1.html`:

| Token | Light | Dark |
|---|---|---|
| `desk` | `#EDEAE4` | `#0F1012` |
| `library.bg` | `#F3F1EC` | `#141517` (derived) |
| `paper.white / cream / night` | `#FFFFFF` / `#F6F0E1` / `#1B1C1F` | same (paper is per-notebook) |
| `ink.primary` | `#1E2129` | `#E9E8E4` |
| `ink.blue / red` | `#2C4FD6` / `#D2402F` | `#5FD3C4` (teal) / `#FF8FB1` (pink) |
| `ink.accent (amber)` | `#E0A400` | `#FFC764` |
| `glass.fill / border` | `rgba(255,255,255,.72)` / `rgba(0,0,0,.07)` | `rgba(40,41,46,.72)` / `rgba(255,255,255,.10)` |
| `text.secondary` | `#8A8C92` | `#A9ABB2` |
| `template.line` | `rgba(30,33,41,.16)` | `rgba(255,255,255,.09)` |
| Palette (11) | `#1E2129 #5D6470 #2C4FD6 #1E8E6E #D2402F #E07A1F #7E4FD8 #C2457E #0FA3B1 #8D6E4C #E8B800` | adapted (below) |
| Covers (8) | `#8E9F87 #C07F5E #2F3B57 #D9C9AC #6B4A5E #3B3C40 #9DB4C9 #E3A5A0` | same |

Geometry: capsule height 52, radius 26, blur 24 + saturate 180 %; tool button 44×40 r20, active = 8 % ink tint + 4 pt dot in the current color; quick-color swatch 22 pt, selected ring 2 pt paper + 3.5 pt color; page radius 4, shadow `0 12 40 -12 rgba(40,30,10,.18)`; pages-overview thumb 176×228 r6, selected ring 3 pt blue; cover 150×196, radius 5/12 (spine); popover 328 w r24. Type: SF Pro for UI, **Instrument Serif** (OFL, bundled) for notebook titles and the pages-overview heading. Caveat in the mocks is stand-in handwriting; not shipped.

**Ink color model.** `InkColor` is `semantic(.primary | .blue | .red | .accent)` or `custom(rgba)`. Semantic colors resolve per paper theme at render time (so the same stroke is near-black on cream and off-white on Night). Custom colors on Night paper get their OKLCH lightness remapped (`L' = clamp(max(L, 1.2 − L), 0.65, 0.95)`, hue/chroma kept: dark colors mirror light, light colors stay, never darker) unless the notebook setting "Keep exact colors" is on. Export resolves against the export paper theme (§9).

## 11. Perf budgets, mapped

| Budget | Mechanism | Measured by |
|---|---|---|
| Cold launch → library < 400 ms | no work in `App.init`, index read on actor during first frame, Metal device created lazily on first editor open, no third-party deps, static linking of packages | `XCTApplicationLaunchMetric`, MetricKit `MXAppLaunchMetric`, signpost `launch.firstFrame` |
| Open notebook < 150 ms | index holds layout facts; thumbnail-first frame; page 1 strokes lz4 < 10 ms; tile render on background queue | signpost `notebook.open` → `canvas.firstSharpTile`, `XCTOSSignpostMetric` |
| Ink latency hardware floor | §3.3: touch-event-driven draw, predicted tail, 2 drawables, 120 Hz | `touch.timestamp` → `presentedTime`, debug HUD, device-only test vs PencilKit baseline |
| Scroll/zoom 120 Hz, 100+ pages | §5: viewport-pinned Metal view, tiles ± 1 page, bucket scaling during pinch, stroke data eviction | `XCTOSSignpostMetric` on `canvas.frame` over the 300-page fixture, MetricKit `MXAnimationMetric` hitch rate, Instruments Hitches |
| No spinners | §1.4: every async path has an on-disk placeholder | code review rule; UI test asserts no `ProgressView` in editor/library |

## 12. Instrumentation and perf tests

- `Perf` package: `Signpost` enum wrapping `OSSignposter` with fixed names (`launch.firstFrame`, `notebook.open`, `canvas.firstSharpTile`, `canvas.frame`, `tile.render`, `stroke.commit`, `doc.checkpoint`, `thumb.render`, `export.pdf`). MetricKit subscriber logs launch/hang/animation payloads to a local JSON for inspection.
- Debug HUD (debug builds, 3-finger triple-tap): frame time, hitch count, ink latency p50/p95, resident tiles/MB, WAL size.
- `PerfTests` target: `measure(metrics:)` with `XCTApplicationLaunchMetric`, `XCTOSSignpostMetric`, `XCTCPUMetric`, `XCTMemoryMetric` over `Fixtures/` notebooks (1, 10, 100, 300 pages). Baselines checked in per simulator model. CI gate: fail on > 10 % regression vs baseline. Simulator numbers are for *relative* regression only; absolute budgets are verified on device, on a checklist in the PR template.
- Fixture generator (headless CLI in `Document`): synthetic notebooks with realistic stroke density (~400 strokes/page, ~60 samples/stroke).

## 13. Testing, CI, lint

- Unit (headless, `swift test` per package): codec round-trip + fuzz, WAL replay, migrations, geometry (tessellation invariants, hit-tests), eraser split, lasso selection, `EditStack` inverse properties, library search, PDF output page count and bbox.
- Renderer snapshot tests (simulator): render fixture pages via `engine.render` and compare to golden PNGs with a perceptual tolerance; same fixtures through both engines to keep the PencilKit adapter honest.
- UI smoke (simulator, `XCUITest`): launch → create notebook → draw a stroke (XCUI drag) → back → cover updated → export produces a PDF.
- Perf tests (§12).
- GitHub Actions, macOS runner (`macos-26` image if available, else `macos-15` with a pinned Xcode via `xcode-select`):
  1. `lint`: `swiftformat --lint .` and `swiftlint --strict` (configs at repo root; SwiftLint rules: strict concurrency-friendly defaults, no `force_unwrapping`, no `print`).
  2. `packages`: `swift test` for every headless package, parallel matrix. Runs today with CLT only.
  3. `ios`: `xcodegen generate` → `xcodebuild test` on an iPad Pro simulator, `xcbeautify`, DerivedData cache keyed on `Package.resolved` + `project.yml`.
  4. `perf` (nightly + label `run-perf`): `PerfTests`, compares against baselines, posts a summary comment.
- `project.yml` is the source of truth; `*.xcodeproj` is gitignored.

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Metal engine misses latency/quality parity | Headline feature | Week-1 spike with hard numbers vs PencilKit; PencilKit adapter is the fallback behind the seam; decision point end of week 3 |
| Fountain/brush look worse than Apple's inks | Beauty | Iterate pen profiles against golden handwriting samples; ship fountain + ballpoint polished, brush can be P1 |
| 120 Hz scroll with tiles + live stroke on 8 GB iPads | Budget | Memory budgets scaled by device, eviction tested under `didReceiveMemoryWarning`, 300-page fixture in CI |
| Liquid Glass legibility over busy ink | Chrome | `.regular` (not `.clear`) glass over the canvas; capsules sit over the desk margin where possible; snapshot tests in light/dark |
| Swift 6 strict concurrency friction with UIKit/Metal callbacks | Velocity | Clear actor boundaries (§2); `Sendable` value model; review any `nonisolated(unsafe)` |
| Partial eraser on dense strokes feels slow | Tool feel | Spatial index + per-gesture batching; measure on 400-stroke page |

## 15. Decisions

Resolved:

1. **Name**: Notespace. Bundle ID `com.abhey.notespace` (one line in `project.yml` if it changes).
2. **Minimum iPadOS**: 26. UI uses Liquid Glass throughout (§7).
3. **Notebook extension**: `.nb`, UTType `com.abhey.notespace.notebook`.
4. **Finger drawing**: Pencil-only by default; setting to allow finger.
5. **Page size**: fixed A4 portrait on Day 0.
6. **Night paper + custom colors**: auto lightness remap, "Keep exact colors" per notebook.
7. **Notebooks location**: `Documents/Notebooks`, file sharing off until the format is stable.
8. **Toolbar**: dynamic — floats top by default, drag to dock top/bottom/left/right, pinch-in to compact pill, tap to expand (§7).

## 16. Future (not Day 0, designed for)

iCloud sync (ship the `PageEdit` journal; IDs and `rev`s already in place). PDF import/annotation (`PageBackground.pdf`, background texture pass). Handwriting search/OCR (Vision over `engine.render` output, index in `Library`). Infinite canvas (page layout is already frame-based; one unbounded page). Text boxes/shapes (new `PageItem` kinds alongside `Stroke`). Collaboration (journal + IDs again).

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
    InkModel/                 Stroke, Sample, Page, Notebook, PageEdit, PageSnapshot, InkColor (pure Swift, Sendable)
    InkGeometry/              smoothing, outline tessellation, hit-testing, spatial index (pure Swift)
    InkEngine/                InkEngine protocol + shared input pipeline types (UIKit, no Metal)
    InkEngineMetal/           Metal renderer, tile cache, shaders (.metal)
    InkEnginePencilKit/       PKCanvasView adapter – spike baseline / fallback
    Tools/                    tool state machine, eraser, lasso, undo stack (depends InkModel, InkGeometry)
    Editing/                  EditPipeline: the one serial path for every notebook change (store → mirror → history)
    Canvas/                   page layout, virtualization, scroll/zoom host, thumbnails (UIKit)
    Document/                 package format, codec, WAL autosave, migrations (Foundation only)
    Library/                  index store, search, folders (Foundation only)
    Export/                   PDF renderer (CoreGraphics)
    DesignSystem/             tokens, glass capsule, typography, themes (SwiftUI)
    Perf/                     signposts, MetricKit, debug HUD
    Fixtures/                 dev-only: FixtureGen library + `notespace-fixtures` CLI (depends Document)
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
 ├─ Editing ─ Tools, Document
 ├─ Tools       ├─ InkEnginePencilKit ├─ InkEngine ─┐
 ├─ Library     │                    │             ├─ InkGeometry ─ InkModel
 ├─ Export ─────┤                    │             │
 ├─ Document ───┘                    └─────────────┘
 ├─ DesignSystem
 └─ Perf
```

Headless-testable with `swift test` on macOS: `InkModel`, `InkGeometry`, `Document`, `Library`, `Tools`, `Editing`, `Export` (CoreGraphics is available on macOS), and `Canvas`'s `PageLayout`, `PageWindow` and `PageResidency` (its UIKit host compiles out). Simulator-only: `InkEngine*`, the rest of `Canvas`, `DesignSystem`, App.

Concurrency: value types everywhere in `InkModel` (`Sendable` structs). UIKit/Metal view classes are `@MainActor`. Background work lives in actors (`DocumentStore`, `LibraryStore`, `ThumbnailService`, `TileRenderer`). No `@unchecked Sendable` without a comment explaining why.

## 3. Ink engine: PencilKit (decided by spike #16)

**Decision (2026-10-24): PencilKit is the shipping ink engine.** On an M1 iPad Pro the user found PencilKit "way smoother" than our best Metal path (28 ms touch→present at 120 Hz via `CAMetalDisplayLink`; the touch-driven pattern stayed at 60 Hz). Results: `docs/spikes/ink-latency.md`.

What stays ours: the document model (`InkModel`), file format, WAL autosave, `EditStack` undo, library, PDF export, and all chrome. PencilKit owns live input, prediction, and stroke rendering, behind the `InkEngine` seam (§3.1) via `InkEnginePencilKit`.

Hybrid canvas:
- **Canvases**: every visible page gets a `PKCanvasView` from a small pool (`maximumCanvases`, 6; pages nearest the viewport center first), covering only the visible part of the page (`CanvasPlacement`), `drawingPolicy = .pencilOnly` by default, scrolling disabled (our `UIScrollView` owns scroll/zoom). No "active page": the Pencil lands on whichever page's canvas is under it. A canvas keeps its page for as long as it is assigned (never re-targeted mid-stroke, so a stroke commits to the page it began on) and is emptied when freed, so a pooled canvas never carries one page's tiles onto another (the one-canvas design showed the previous page's ink on the page it moved to until PencilKit redrew: "ghost ink" after a pinch; render-only, nothing was saved to the wrong page).
- **Other visible pages**: `PKDrawing.image(from:scale:)` rendered off-main into a page-image cache (zoom buckets, memory budget, LRU), so ink looks identical everywhere. This replaces the Metal tile cache.
- **Commit path**: `PKCanvasViewDelegate.canvasViewDrawingDidChange` → diff new `PKStroke`s → `Stroke` (adapter conversion, already tested) → `PageEdit` → `EditStack` + `DocumentStore`. Our model remains the source of truth; `PKDrawing` is a view of it.
- **Lossless (#71)**: a captured `PKStroke` keeps its ink, `randomSeed`, render group and grain offset (iOS 27), and per-point size, opacity, `secondaryScale`, `threshold`, `lateralJitter` in `Stroke.rendering` (format v2, §4.3; live watercolor strokes set a render group and `secondaryScale`, without which they redraw ~8 % darker), so canvas rebuilds, inactive rasters, reloads and export draw exactly what PencilKit drew (`PKStroke → Stroke → file → Stroke → PKStroke` renders pixel-identical; tested). PencilKit quantizes point fields on store (opacity, altitude, threshold in 1/65535 steps, azimuth in 2π/65535, force and height/width to 0.001, lateral jitter to 0.1) and re-quantizing read-back values can land a step off, so the adapter writes them a quarter step into their bucket. Strokes without a rendering (v1, fixtures) derive sizes from the pen profile with a seed from the stroke ID.
- **Rasters**: every visible page (`PageLayerView`) shows `PKDrawing.image` of the stored strokes plus strokes still on their way to the document, rendered with light traits (the canvases are pinned light), masked out where its canvas has drawn (`inkHole`, no double ink) and whole until then (`canvasViewDidFinishRendering`, 0.5 s cap), so ink never blinks out when a canvas moves to a page. A raster is never cleared before its replacement is ready. Pages beyond the canvas pool show their raster only. **Page-image cache (#70)**: rasters render on a `RasterRenderQueue` (two at a time, nearest the viewport center first, one waiting job per page, `page.image.render` signposts) into `InkRasterCache` (per page × content × zoom bucket 0.5/1/2/4 × screen scale; LRU by bytes, 1/32 of RAM ≤ 128 MB, emptied on memory warning; a new raster drops the page's rasters of older content). While one renders the page shows, best first: the same ink at the nearest cached bucket (scaled by the layer) → its newest raster of any content → its thumbnail `thumbs/<id>.heic` decoded off main (opaque, scaled to the page width, top-aligned) → flat paper and template marks; nothing blocks scrolling. A snapshot whose strokes are still loading (`PageSnapshot.isLoaded == false`, from `PageResidency`) shows its thumbnail whole, its empty canvas cutting no hole, and the first raster crossfades the thumbnail out in 120 ms (`Tokens.Motion.thumbnailCrossfadeDuration`, #43). The debug HUD's `page img` row is resident MB and queue depth.
- **Zoom (one transform)**: the engine view is content-sized and sits **inside the host's zoom view**, so UIKit's one zoom transform moves paper, ink, lasso chrome and input together on every frame of a pinch, bounce, fling or rubber band, whatever UIKit animates and however it animates it (the earlier design, a canvas pinned to the visible rect and following the paper by its own transform, drifted whenever the two hierarchies disagreed: PencilKit re-tiling frames late, `UIScrollView` correcting an overscroll inside a `UIView` animation block the canvas inherited and the paper didn't). A canvas renders at the viewport zoom (`zoomScale` pinned, min = max, so it has no pinch of its own and draws at screen resolution) and is scaled back by `1/zoom`, so in content space it covers exactly its page region (`CanvasPlacement`: page point p lands at `pageOrigin + p`, same as the paper). During a pinch or its bounce (`Viewport.isZooming`) canvases are left alone, the transform scales their last tiles, and the page raster shows around them (zooming out reveals more page); when it ends each canvas takes the final zoom once, in place (same geometry on screen, finer tiles). Scrolling at one zoom only moves bounds and centers. Template marks re-rasterize at the settled zoom (`contentsScale`). `viewportDidChange` runs without animation. Natural rubber-banding on all edges; the horizontal offset is pinned while pinching only so a narrow page stays centered. No double-tap zoom. **Fit width (#130)**: a pinch that ends within 5 % of the zoom at which the page spans the view (`fillZoom`) eases onto it (0.3 s, light haptic; `snapToFitWidth` → `animateZoom`, `isSnapping` keeps the engine hands-off until the end); never mid-pinch, never during a range bounce. At fit width the side insets are 0 (`PageLayout.sideInset`: centered when narrower, the 16 pt desk margin grown in over the first 16 pt of overflow when wider), so the page covers the screen edge to edge.
- **Tools**: pens map to `PKInkingTool` ink types (fountain → `.fountainPen`, ballpoint → `.pen`, brush → `.watercolor`, highlighter → `.marker`); eraser: not PencilKit's; our input view feeds eraser samples to `Tools` (model-driven, §6, #28); lasso → our own input + model (not `PKLassoTool`, whose selection lives in `PKDrawing` and bypasses `EditStack`; §6). Laser pointer (#159) → our own input, drawn by the engine only (`+Laser`, `LaserTrail`): a neon tip dot and, in trail mode, the trail behind it (thin white core, red rim, soft red glow), fully bright while the Pencil touches and for 0.3 s after lift, then fading over 0.7 s (one Core Animation fade, no display link); touching again mid-fade restores it and adds to it; never committed, no undo; Pencil only unless finger drawing is on. Pencil double-tap/squeeze via `UIPencilInteraction`. Widths: PencilKit width = ink `defaultWidth` × toolbar width / `referenceWidth` (ballpoint 4.2, fountain 5.5, brush 5, highlighter 16), clamped to `validWidthRange` (iOS 27: pen 2.68 in 0.88–25.7, fountain pen 4 in 1.5–14, watercolor 40 in 10–80, marker 20.6 in 7.5–60). Pen presets 1.5/**2.5**/4/6/8 → ballpoint 0.96/**1.6**/2.55/3.83/5.1, fountain 1.5/**1.82**/2.91/4.36/5.82, brush 12/**20**/32/48/64; highlighter 10/**16**/24 → 12.9/**20.6**/30.9. The default (bold) is a fine pen; fresh installs default to ballpoint (the fountain default at PencilKit's own width read marker-thick on device). Stored strokes keep their exact point sizes (format v2), so only new ink changes.
- **Night paper**: PencilKit adapts ink colors for dark appearance; Night pages set the canvas to dark style. Verify against §10's remap.
- **Undo**: PencilKit's internal undo is disabled/bypassed; all undo goes through `EditStack` (§6).

The Metal engine (`InkEngineMetal`, #19) stays in the repo, unwired, as a future option (e.g. custom brushes); if revived it must use `CAMetalDisplayLink`. The sections below describing the Metal pipeline are historical.

### Original analysis (pre-spike)


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
    var view: UIView { get }                          // content-sized, inside the host's zoom view; draws only the viewport
    var delegate: InkEngineDelegate? { get set }

    func setViewport(_ v: Viewport)                   // content offset + zoom + visible page frames
    func setPages(_ pages: [PageSnapshot])            // immutable stroke snapshots for visible pages
    func prepare(_ page: PageSnapshot) async          // a loaded page's setPages work, off main
    func setTool(_ tool: ToolConfiguration)
    func setTheme(_ theme: PaperTheme)
    func setPalette(_ palette: InkPalette)            // "Keep exact colors" toggled
    var selectionColor: UIColor { get set }           // live lasso path
    var thumbnailURL: ((PageID) -> URL?)? { get set } // shown while a page's ink loads/renders
    func apply(_ edit: PageEdit, to page: PageID)     // undo/redo/lasso go through here
    func setSelectionPreview(_ p: SelectionPreview?)  // lasso drag: lift strokes, draw them transformed
    func prepareSelectionPreview(_ s: Set<StrokeID>, on page: PageID)  // ready the lift off main
    func render(page: PageSnapshot, size: CGSize, scale: CGFloat) async -> CGImage?  // thumbnails, export raster fallback; nil only for degenerate size
}

@MainActor public protocol InkEngineDelegate: AnyObject {
    func engine(_ e: InkEngine, didCommit stroke: Stroke, to page: PageID)
    func engine(_ e: InkEngine, didReceiveEraser samples: [Sample], to page: PageID)  // Tools package resolves what gets erased
    func engine(_ e: InkEngine, didReceiveLasso path: [CGPoint], to page: PageID)
    func engineDidBeginStroke(_ e: InkEngine)         // clears the lasso selection
    func engine(_ e: InkEngine, didShowSharpInkOn page: PageID)  // `canvas.firstSharpTile` signpost
}
```

Rules: the engine never mutates the document. It emits committed strokes/eraser/lasso input; `Tools` turns them into `PageEdit`s; `DocumentStore` applies them and calls back `apply`. One direction, one source of truth.

The app talks to the engine only through this protocol: it constructs `PencilKitInkEngine` (and sets its crossfade duration) in one place, never downcasts. `InkEngineTestSupport.RecordingInkEngine` is the second adapter: canvas host and page residency tests run against it.

Colors: engines take an `InkPalette` (paper, template line, `ink(_:on:)`) at init; the app adapts `DesignSystem` tokens, so hex values stay out of engines (§10).

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

As built (#19, `MetalInkEngine`):

- **Frame** = one command buffer: committed content (`CommittedContentRenderer`: until the tile cache lands, one viewport-sized composite texture re-rendered only when viewport/pages/theme/committed ink change), then a drawable pass that copies it and draws pending strokes (committed, not yet echoed back via `apply`) and the live stroke on top. Committed strokes live in per-page GPU buffers built off main (strips cached by stroke ID; one indexed triangle-strip draw per page per pass). #22 swaps the composite for tiles behind the same protocol; both render through `SceneEncoder`.
- **Highlighter**: each stroke goes into a coverage target with max blending, then resolves onto the page; strokes whose bounds don't overlap share a coverage pass. It is tessellated as a chain of capsules rather than InkGeometry's outline strip (a wide flat-capped strip folds at tight turns), with the chisel ends clipped in the shader. On Night paper it uses **screen** instead of multiply, which would all but vanish on `#1B1C1F`.
- `displaySyncEnabled` is macOS-only; iOS always presents in sync with the display. The layer is BGRA8 tagged sRGB (palette colors are sRGB; Core Animation matches them to the P3 panel).
- The simulator SDK has no `addPresentedHandler`, so the probe records nothing there.

## 4. Document model and file format

### 4.1 Model (`InkModel`)

```swift
struct Notebook { id: NotebookID; title; cover: CoverColor; paper: PaperStyle; theme: PaperTheme; keepsExactColors: Bool; pageSize: CGSize; pages: [PageID]; createdAt; modifiedAt; rev: UInt64 }
struct Page     { id: PageID; template: PageTemplate; strokes: [Stroke]; images: [PageImage]; rev: UInt64 }
struct PageImage { id: ImageID; asset: ImageAssetID /* images/<asset>.heic */; frame: CGRect /* pt */ }   // #157, beneath every stroke
struct Stroke   { id: StrokeID (UUIDv7); tool: PenKind; color: InkColor; width: Float; samples: [Sample]; rendering: StrokeRendering?; bounds: CGRect }
struct Sample   { x, y: Float; force: Float /* 0...1 */; altitude: Float; azimuth: Float; t: Float /* s since stroke start */ }  // 24 B
struct StrokeRendering { ink: String /* PKInk.InkType raw value */; randomSeed: UInt32; points: [PointRendering] /* parallel to samples */; renderGroupID: UUID?; grainOffset: CGPoint? }
struct PointRendering  { width, height: Float /* PKStrokePoint.size */; opacity, secondaryScale, threshold, lateralJitter: Float }
enum   PageEdit { add([PlacedStroke]); remove([PlacedStroke]); replace(old: [PlacedStroke], new: [PlacedStroke]); transform([StrokeID], forward: CGAffineTransform, backward: CGAffineTransform); recolor([ColorChange])
                  addImages([PlacedImage]); removeImages([PlacedImage]); transformImages([ImageID], forward:, backward:) }
// PlacedStroke = (z-index, Stroke); PlacedImage = (z-index, PageImage); ColorChange = (id, from, to).
// Build via Page.addEdit/removeEdit/replaceEdit/transformEdit/recolorEdit and addImagesEdit/removeImagesEdit/transformImagesEdit.
```

Strokes store **raw samples, not outlines**, so improving the tessellation later re-renders old notes better. PencilKit-captured strokes also carry `rendering`: exactly what PencilKit drew (§3, #71), kept out of `Sample` so the hot sample array stays 24 B. `InkGeometry` (hit tests, PDF export) uses what PencilKit *draws* for the stored point sizes when present (`InkNib`: PencilKit does not paint a point as wide as its `size`; pen is `2 × width − 4`, fountain pen and marker are chisels along the azimuth, watercolor `1.63 × width` × wash; measured, pinned by `InkWidthTests`), the pen profile otherwise; `derivedRendering` inverts the same map so profile widths draw as intended. **Photos (#157)**: a page's `images` are placements (ID, asset, frame) beneath every stroke; the bytes live once per asset in the package (`images/<asset>.heic`, ≤ 2048 px long edge, written before the edit that places them and never rewritten; duplicates share the asset; deleting leaves the file so undo can bring the placement back). The three image edits are self-contained like the stroke ones, so the journal, undo and lasso treat photos and ink alike; `touchesImagesOnly` lets the engine skip canvas work for them. `PageEdit` is the one edit vocabulary used by tools, undo/redo, autosave journal, and (later) sync. Every `PageEdit` carries the prior state its undo needs (removed strokes with z-index, prior colors, inverse matrix), so `inverse()` is pure and `e.inverse().inverse() == e`.

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
  images/
    <assetID>.heic       photo bytes placed on pages (#157): written once, shared by duplicates, kept on delete
  backup-v1/             manifest.json + pages/ as they were before the v1 → v2 migration (§4.5)
  backgrounds/<uuid>.pdf imported PDF (#119); its pages are PageBackground.pdf(file, page)
```

Per-page files are deliberate: page-scoped loads (open page 1 without reading page 90), page-scoped autosave, page-scoped sync conflicts later.

`Document.NotebookPackage` owns this layout: create (staged in a hidden sibling dir, then renamed into place; optionally with a lazy sequence of inked pages for import/duplicate/fixtures), open (manifest only), `loadPage` (one stroke file), `savePages` (stroke files, then one manifest write), insert/delete/move page. Every file write is temp + `rename`. Manifest page order is the `pages` array itself (no separate `pageOrder`).

### 4.3 Stroke codec (`Document`)

Custom little-endian binary, no schema library:

```
header: magic "INKS" | u16 formatVersion | u32 strokeCount | u32 flags (bit0: lz4) | u32 bodyLength (uncompressed) | u32 crc32
stroke: u128 id | u8 tool | InkColor (u8 kind + 4 B: semantic slot,0,0,0 or r,g,b,a) | f32 width | u32 sampleCount | samples[f32 x,y,force,altitude,azimuth,t]
        | rendering (v2): u8 flags (bit0 present, bit1 square: h = w, bit2 uniform opacity, bit3 group, bit4 grain, bit5 extras)
          [u8 inkLength | ink UTF-8 | u32 randomSeed | u128 group? | f64 grain x,y? | f32 opacity if uniform
           | sampleCount × (f32 w [, f32 h] [, f32 opacity] [, f32 secondaryScale, threshold, lateralJitter])]
images (v3, after the strokes): u32 imageCount | imageCount × (u128 id | u128 asset | f64 x, y, w, h)
```

Whole body after header compressed with `Compression` framework lz4 (`COMPRESSION_LZ4`), kept only if smaller. `bodyLength` sizes the decode buffer; CRC-32 covers the header and stored body, so damage is a typed error, never garbage ink. Decoder validates every length before reading and never traps (fuzzed). Version 1 files (no rendering block) still decode; version 3 (#157) appends the page's image placements, which versions 1–2 lack. Measured (M-series Mac, release, #71): 400 × 60-sample page with full per-point rendering (the v2 worst case: every field per point, f64 secondaryScale, group, grain; 1.27 MB lz4) decodes in ~0.93 ms (typical pen data, square points + one opacity: ~0.67 ms; no rendering: ~0.43 ms); 100-page notebook manifest + page 1 in ~1.5 ms. Raw Float32 samples barely compress (~2 %); quantize/delta-code later only if size matters.

### 4.4 Autosave and crash safety

- Every committed `PageEdit` is appended synchronously-cheap to `pages/<id>.wal` (one record, O(edit size)) from the `DocumentStore` actor (own serial queue). Pen-up to durable: < 50 ms (budget for the append itself: p95 < 5 ms), never on main. Measured (M-series Mac, release, shared loaded machine): one 120-sample stroke with full v2 rendering p50 0.28 ms, p95 0.52 ms (v1 strokes: p50 0.3–0.5 ms, p95 0.7–2.2 ms).
- WAL format (`Document.Journal`): 32 B header (`INKW`, version, base rev, base stroke-file length + CRC) then records `u32 length | u32 crc32 | u64 rev | u8 kind | binary PageEdit` (strokes in the stroke-codec layout of the journal's version; kinds 0–4 stroke edits, 5–7 image edits from version 3, #157). A journal from an older version is replayed, then folded into a stroke file at once, so new records never land in it. Each append is `pwrite` + `F_BARRIERFSYNC`: an app kill loses nothing that `apply` returned for; power loss/panic recovers a consistent, in-order prefix (may lose the newest edits still in the drive cache). `F_FULLFSYNC` would cost ~8× per append.
- Checkpoint: after 2 s idle (one debounce task, not a timer per edit), on page leave (`evict(page:)`), on background/resign-active (`flush()`), or when WAL > 1 MB: rewrite `<id>.strokes` to a temp file, barrier-sync, `rename`, then manifest the same way with bumped `rev`s, then delete WAL. 100 dense dirty pages: v1 data (~58 MB) 170–260 ms; v2 typical pen data ~390 ms, worst case ~505 ms (#71).
- Open: if a `.wal` exists, replay it over `.strokes` before presenting. A torn or corrupt tail is detected by length/CRC and truncated; earlier records are kept. Replay is idempotent: a WAL whose base no longer matches the stroke file (checkpoint crashed before deleting it) is already folded in and is discarded, never replayed twice.
- Never a "Save" button. Never a dirty-state dialog.

### 4.5 Versioning, migration, forward-compat

- `formatVersion` in `manifest.json` and in each stroke file and journal header. Integer, bumped on any incompatible change. `Document/Migrations/` holds the steps run on open (`NotebookPackage.open`). **v1 → v2** (#71, PencilKit rendering data): copy `manifest.json` + `pages/` to `backup-v1/` once (staged, then renamed; APFS clones), load every inked page (journal replayed) and write it back as v2, then the manifest (`modifiedAt` untouched), then delete the journals. Crash-safe and idempotent: until the manifest says v2 the next open redoes it. v1 strokes keep no rendering (drawn from the pen profile, as before).
- Open refuses newer `formatVersion` with a clear message (not a crash).
- Unknown JSON keys are preserved round-trip (`extra: [String: JSONValue]` on `Manifest` and `PageEntry`).
- **Sync-ready without sync**: every entity has a stable ID (UUIDv7, time-ordered); per-notebook and per-page `rev` counters; edits are already an append-only journal of `PageEdit`s. Adding iCloud later means shipping the journal, not changing the model. No file paths stored anywhere; IDs only.
- **PDF import** (#119): `PageEntry.background` is `.template` (omitted from JSON) or `.pdf(file, page)` (`{"kind": "pdf", "file", "page"}`) naming a page of `backgrounds/<file>`. Import always makes a new notebook (`NotebookPackage.create(at:notebook:pdf:)`): the PDF is copied in, one blank-template page per PDF page, notebook page size = A4 wide with the first page's aspect (`PDFSource.notebookPageSize`, so widening (#129) keeps its A4 base; other pages are aspect-fitted, centered on white). No format bump: older builds refuse such a manifest (unknown background kind) rather than drop pages. The PDF stays vector: `PageArtwork` (InkModel) draws it; `InkEngine.pageArtwork` feeds the PencilKit engine, which draws it in a `CATiledLayer` under the template and ink (lazy, off main, sharp at every zoom) and in thumbnails; export draws the original page under the ink. Undoing a page delete restores its background.

## 5. Canvas: multi-page scroll, virtualization, tiles

### 5.1 Host

`CanvasHostView` (`Canvas`, UIKit, wrapped in `UIViewRepresentable`): a `UIScrollView` for native 120 Hz physics, rubber-banding, and pinch zoom (`minimumZoomScale 0.5`, `maximumZoomScale 4`), with a transparent content view of total notebook size that the engine's `view` fills (content space, unzoomed points), so the scroll view's zoom transform applies to paper and ink alike (§3, Zoom). Content-sized views draw nothing themselves, so they cost no memory; the engine creates layers and canvases only for the visible pages. `scrollViewDidScroll`/`DidZoom` → `engine.setViewport(...)`. The host's overlay (lasso chrome) stays pinned to the visible rect.

### 5.2 Page layout

`PageLayout` (pure Swift): fixed page size per notebook (A4 portrait 595×842 pt default), vertical stack with no gap (#162): pages touch, and each page below the first draws a one-screen-pixel hairline in the template mark color along its top edge (`PageLayerView.seamLayer`, above its image). Precomputed `[pageFrame]`; visible pages by binary search. Pages have no view objects; they are just frames the engine is told about. Page indicator "3 of 11" derives from the frame whose center is nearest the viewport center.

**Expanding sideways (#129).** Every page of a notebook shares one width; the user widens it by pressing and holding within 24 pt of a page's left or right edge (finger or pointer, no handle at rest) and dragging. The drag is continuous (any width), stopped inward at the original width or the furthest ink on any page and outward at +200 % per side, with a haptic at each stop and a width tag ("+50 %") beside the finger. The host (`CanvasHostView+SideGrab`) previews it live without touching the engine: paper-colored strips beside each visible page carry the template's marks as a phase-aligned tiled pattern (no re-rasterizing as they grow), a hairline marks the original edge, and for a left grab the content is shifted inside the scroll view by the paper added so the ink never moves (`sizeContent`, `makeViewport`). Release freezes the frame (`snapshotView`) and hands the session a `PageWidthChange`: `NotebookSession+Width` sets the new geometry on residency and host, and for a left change applies one `.transform` (translate) per inked page through the store, mirror and engine, then writes `pageSize` and `leftExtension` to the manifest; the frozen frame lifts once the visible pages report sharp ink (or after 400 ms) and the insets ease to their settled values. Page space keeps its origin at the paper's top-left, so strokes move with a left extension; templates take `leftExtension` so their columns stay under the ink (`TemplateGeometry(_:size:leftExtension:)`, used by the engine, thumbnails and PDF export, whose page is the widened size). The shift rewrites every page, so it clears the undo history instead of being a step in it.

### 5.3 Templates

`PageTemplate`: `blank | lined(spacing) | dotted(spacing) | grid(spacing) | cornell`. Rendered procedurally by the engine (§3.3). Paper styles: White `#FFFFFF`, Cream `#F6F0E1`, Night `#1B1C1F`. Editor desk behind pages: `#EDEAE4` light, `#0F1012` dark.

### 5.4 Tile cache

- `TileRenderer` (non-main, own `MTLCommandQueue`, serial queue): renders 512 px tiles per page per zoom bucket (0.5, 1, 2, 4) into an `MTLHeap`-backed texture pool. LRU by bytes, budget 256 MB on 8 GB iPads (scaled by `ProcessInfo.physicalMemory`), evict on `didReceiveMemoryWarning`.
- Residency: tiles for visible pages ± 1 page. Others evicted lazily. Stroke data for pages outside ± 3 pages is dropped from memory (reloaded from disk on demand, < 10 ms per page).
- `PageResidency` (`Canvas`, pure Swift) owns this for strokes: page order, the current `PageWindow` (`isVisible(id)`), the loaded pages (the page mirror, §6), background loads (2 at a time) and store evictions. It feeds the engine through a two-call `PageSink` port (`setPages`, `apply`); tests use a recording sink against a real `DocumentStore`. Code that only reads a page (thumbnails, "has ink?") uses `peek(id)`: the mirror's copy, or read and released, and never releases a page the window is loading or keeps.
- Zoom gesture: scale existing bucket tiles on the GPU (cheap, slightly soft), then re-render at the new bucket on gesture end. No blank tiles: a missing tile falls back to the nearest bucket, then to the page thumbnail, then to flat paper.
- Invalidation is rect-based per page; a committed stroke only redraws intersecting tiles.

### 5.5 Thumbnails

`ThumbnailService` actor (`Canvas`, #33): debounced 1 s after the last edit on a page, and on page leave/close/background, renders `thumbs/<pageID>.heic` (176×228 pt @2x, page scaled to fill, top-aligned) via `engine.render(...)` off main; also `cover.heic` (344×196 pt @2x: page 1 from (30, 26) pt, 500 pt wide, the framing of the library's paper placeholder) when page 1 changes. Rendering, HEIC encoding and the temp + `rename` write run one page at a time on a detached task; each is a `thumb.render` signpost; debug asserts none of it runs on main. Notebooks from before thumbnails existed get theirs lazily as pages load (`ensure`: two `stat`s when present); a paper or theme change regenerates every page, one in memory at a time. After `cover.heic` is written the session tells the library (`coverDidChange`), which bumps the card's cache key so the file is re-decoded without waiting for the next checkpoint's `modifiedAt`. The Library and pages overview read HEIC from disk only; never render on demand in UI.

### 5.6 Pages overview

As built (#32, mock §04): `PagesOverview` is a SwiftUI overlay in the editor's `ZStack` (regular material + desk tint; the chrome is swapped out while it is up) with a `LazyVGrid` of `PageThumb`s (176×228 r6, `thumbs/<id>.heic` read lazily per visible cell via `ThumbnailImage`, paper + `PaperPatternView` placeholder until a thumb exists, 3 pt blue ring on the current page from `CanvasViewportState.currentPage`). `PagesModel` (owned by `EditorState`) holds the entries and the actions; `NotebookSession+Pages` performs them: tap → dismiss + `scrollToPage`; long-press-drag onto another thumb → `movePage`; the bottom template capsule → `insertPage(after: current)`; Select → multi-select delete, confirming only when a selected page has ink. Page structure is one undo step each: `PageStructureEdit` (`insert` / `delete` carry template + strokes, `move`) lives in `EditEntry.structure` beside ink steps, so a deleted page comes back with its ink and `EditPipeline` applies both kinds in order. `ThumbnailService.Options.onPageWritten` bumps a cell's cache key when its thumb is rewritten while the overview is up. `pages.overview` signpost: Pages tap → first frame; ≈ 75 ms on 300 pages in the Debug simulator (no per-page cost: cells are lazy). DEBUG `-pagesOverview YES` opens it after `-openNotebook`.

## 6. Tools

`Tools` package, headless-tested. `ToolState` is an `@Observable` main-actor object: current tool, per-tool settings (persisted in `UserDefaults` as a Codable blob), three quick-color slots (default `#1E2129`, `#2C4FD6`, `#D2402F`). The editor gets one value from it, `ToolState.active` (`ActiveTool`: ink with kind/color/width, eraser with mode/size, or lasso — only what that tool uses); the session derives the engine's `ToolConfiguration` and the erase settings from it, and settings of other tools or the toolbar don't reach it.

- **Pens**: fountain / ballpoint / brush, size in page mm per family (`InkSize`, 0.1 mm steps; pens 0.1–2, brush 6–20, highlighter 2–12; `width` = mm × 72/25.4 pt, what the stroke paints), pressure toggle, 11-color palette + custom. PencilKit paints a point narrower than its size (`InkNib`; `.pen` = `2 × size − 4`, nothing ≤ 2), so `pencilKitWidth` = `InkNib.pointSize` (#168).
- **Highlighter**: 3 widths, palette subset, multiply, under-ink (§3.3).
- **Eraser**: stroke mode and partial mode, 3 widths.
  - Hit-testing uses a per-page uniform grid spatial index (`InkGeometry.StrokeIndex`, 64 pt cells) on stroke bounds, then exact outline-vs-circle test.
  - Stroke erase → `PageEdit.remove`.
  - Partial erase → split sample polyline where the eraser disk intersects, emit `PageEdit.replace(old: [id], new: [pieces])`. Pieces get new IDs, keep the original samples outside the disk and cut the stored PencilKit point sizes alongside (disk inflated by half of what the ink draws for each point, `StrokeRendering.drawnWidths`, so the eraser reaches what is visible). Pieces under 0.5 pt are dropped.
  - All pens erasable, highlighter included. Each touch event's edit is applied at once (immediate feedback); at gesture end `EraserRun` collapses the gesture's per-event steps into one edit per page, so undo is one step that applies one edit per page. Budget: < 2 ms hit-test per event on a 400-stroke page (`EraserPerformanceTests`).
- **Lasso**: freeform path closed on pen-up; a stroke is selected if ≥ 50 % of its samples are inside, a photo if its center is (#157). Selection shows a marching-ants hull with resize handles and a context bar (recolor to quick colors / palette for ink, duplicate, delete; a photo-only selection has no colors). Move/resize → `PageEdit.transform` (samples baked, no persisted transform) plus `.transformImages` for photos, one undo step. Recolor → `PageEdit.recolor`.
  - As built (#29): `Tools.LassoSelection` resolves the path, holds the padded convex hull + corner geometry (proportional resize about the opposite corner) and builds each action's single edit (duplicate = `.add` of fresh-ID copies +20 pt). App: `SelectionOverlayView` (a `CanvasHostView.overlay`: marching ants, handles, drag; claims only touches on the selection) and `SelectionBar` (glass context bar: quick colors, palette, duplicate, delete). Drag preview: `InkEngine.setSelectionPreview` — PencilKit renders the selection once into a layer, leaves it off the canvas and only moves the layer per frame. `SelectionMachine` (package `Editing`, headless-tested over a real pipeline) is the one owner of the selection: none → resolving → selected → dragging → committing; the session only feeds it inputs and is its `SelectionDisplay` (overlay + engine preview). On release it commits one transform through `EditPipeline` and keeps the ink lifted until that edit reaches the engine, even if cleared meanwhile; after every action the selection is rebuilt from the saved page (a refused drop follows the real ink, not the drop point). Late results (a lasso resolving, an action saving) are dropped if the selection was cleared or replaced. Cleared by a new gesture, tool change, undo/redo, finger tap outside, or the page leaving the screen.
- **Photos (#157)**: the toolbar's Photo button (after Lasso; not a tool, the current tool stays) opens `PhotoFlyout`: the system `PhotosPicker` embedded `.inline` with its accessory bar hidden (3-wide grid of recents, scroll for older; out of process, so no photo-library permission). One tap: the flyout closes, `PhotoImport.prepare` (off main) bakes orientation, downscales to ≤ 2048 px and encodes HEIC, `DocumentStore.writeImage` lands the bytes (`EditPipeline.run`, ahead of the edit), then `SelectionMachine.insert` commits one `addImages` edit and shows the photo selected: centered in the visible part of the current page at 40 % of its width (`PhotoImport.frame`), ready to move/resize with the lasso chrome. Engine: each `PageLayerView` draws its page's photos as `CALayer`s beneath highlights and ink (`+Photos`; bytes decoded once off main into `PhotoCache`, placeholder meanwhile); a drag moves those layers in place (`SelectionPreview.images`) while the lifted ink image moves above; image-only edits skip the canvas rebuild. Thumbnails and `render(page:)` composite photos over the template; PDF export draws them before the highlights via `PDFExporter.imageLoader`. Widening shifts photos with the ink; page delete/undo carries them (`PageStructureEdit`). Not on Day 0: rotate, crop, other sources (Files, camera, paste, drag-drop), unreferenced-asset cleanup.
- **Undo/redo**: our own `EditStack` (per notebook, ring of 200 `PageEdit`s with page IDs), not `UndoManager` as the store. A thin `UndoManager` bridge registers each edit so system three-finger swipe/tap and keyboard ⌘Z work. Undo coalescing: partial-eraser gesture = 1, lasso drag = 1, each stroke = 1. Every change and every undo/redo runs through `EditPipeline` (package `Editing`) in the order asked, so an undo tapped while a stroke is still saving takes back that stroke; the bridge registers with `UndoManager` at once but moves the stack in pipeline order.
- **Pencil**: double-tap/squeeze → eraser toggle (§3.2). Hover → cursor preview.
- **Options popover (#27)**: tap the active tool on the expanded toolbar → `ToolPopover`, anchored to that button, opening away from the dock on every edge. The focus pill's tool and color are display only; the pill has no popover. Pen: family, live preview, size (`SizeControl`: mm readout, wedge slider between −/+, 3 saved sizes — tap uses, long-press stores current), 11-color palette + `ColorPicker`, pressure. Highlighter: preview, size, 6 colors. Eraser: stroke/partial, 3 sizes. Writes `ToolState` directly → next stroke. Preview = `InkPreview` (`InkEnginePencilKit`): synthetic S-curve as a `PKStroke` (same ink, `pencilKitWidth`, pen-profile sizes), `PKDrawing.image` with light traits; bold inks drawn true-size then scaled to fit. Long-press a toolbar quick color → stores the pen's color. Pressure off (#123) reaches the engine through `ActiveTool.ink(pressure:)` → `ToolConfiguration.pressure`. PencilKit sizes live points from the Pencil's force itself and can't be told not to (its force-blind monoline ink stops at 4 pt), so the PencilKit engine routes those pens through the shared `InkInputView` like the eraser (`LiveStroke.recordsForce` off: samples at `Sample.neutralForce`, tilt kept), and on lift commits a stroke whose stored rendering is one point size throughout (the ink's `pencilKitWidth` at neutral force, as the preview draws it), appended to the canvas as pending like a PencilKit-drawn stroke (`+FlatPen`). While the Pencil is down that same stroke (same ID → same seed) is rendered by PencilKit after every touch (`PKDrawing.image` of its visible bounds at screen × zoom) into a layer on the selection view, kept until the canvas reports a render: live and committed pixels come from the same renderer, so nothing changes at lift (a shape-layer line never matched the ink, most visibly zoomed in). The Metal engine just flattens force the same way. Other renderers (export, derived rendering) see neutral force and draw them flat too.

## 7. Toolbar and chrome

`ToolbarContent(axis:)` (tools, the Photo button (#157), quick colors, undo/redo) is axis-agnostic SwiftUI. `ToolbarHost` makes it **dynamic** (user decision):

```swift
enum ToolbarDock: String, Codable { case top, bottom, left, right }   // left/right render vertically
```

- Default: expanded capsule floating top center (mock §02).
- Drag the toolbar → it tracks the finger, then springs to the nearest dock on release; dock persists.
- Pinch-in on the expanded toolbar → focus mode: compact pill (current tool + color, display only) at the same dock, other chrome hidden. Leave via the pill's chevron or pinch-out on the pill. No compact toolbar outside focus mode (#158).
- All transitions are `glassEffectID` morphs inside one `GlassEffectContainer` with interactive springs; Reduce Motion → crossfade. Toolbar gestures are finger-only and never reach the canvas; Pencil input is unaffected. Tracked in #26.
- As built (#26): drag and pinch are UIKit recognizers (`UIGestureRecognizerRepresentable`, `allowedTouchTypes = [.direct]`); SwiftUI's `MagnifyGesture` never fires over the tool buttons. The toolbar is one `GlassCapsule` whose axis (`AnyLayout`), thickness and content change, so dock changes and expanded ⇄ compact animate the glass itself instead of swapping views. Nearest dock = nearest edge with distances normalized by screen size, plus a short flick projection. `ToolState` persists the dock; focus mode is per editor session, not persisted.

Chrome pieces (mock §02): left capsule (back, title, menu), center capsule (tools), right capsule (pages grid, share, more), bottom-right "3 of 11" pill. **Focus mode** (#158): pinch-in on the toolbar or More → Focus mode morphs the chrome to a single compact pill (mock §05); the page pill stays, dimmed. Sticky: ink, taps, scroll, zoom and lasso drags don't end it. Only the pill's chevron (VoiceOver: "Show toolbar"), pinch-out on the pill, or a Pencil tool-options request leave it. Never entered automatically; not persisted. Dark mode follows system appearance; the paper theme (Night) is per-notebook and independent of system dark mode.

Glass: native Liquid Glass, verified in the iOS 27.1 SDK (all `@available(iOS 26.0, *)`): `glassEffect(_ glass: Glass = .regular, in: some Shape)`, `Glass.regular/.clear/.identity` with `.tint(_:)` and `.interactive()`, `GlassEffectContainer(spacing:)` so neighbouring capsules blend/morph, `glassEffectID(_:in:)` + `glassEffectUnion(id:namespace:)` for morph transitions (toolbar → focus pill), `.buttonStyle(.glass / .glassProminent)`. Rules: the three editor capsules live in one `GlassEffectContainer`; tool buttons use `.interactive()`; active tool tinted with the current ink color at low opacity; focus-mode collapse is a `glassEffectID` morph, not a fade; sheets/popovers use system presentation (glass by default on 26). `DesignSystem` wraps these in `GlassCapsule`/`GlassPill` so tokens stay in one place. No `Material` fallback needed (26 minimum).

## 8. Library

- `LibraryStore` actor over a single index file `Application Support/Library/index.json` (atomic writes). Entries: notebook ID, title, folder ID, cover color, modified, page count, package path relative to the Notebooks root, cover thumb path. Folders: `[Folder {id, name}]`, one level, notebook has at most one `folderID`.
- Cold launch: `LibraryStore.readIndex` decodes the index synchronously while SwiftUI builds the first frame (skipped above 1 MB) and seeds the actor, so the first frame already has the notebooks; notebooks are stored column-wise (one JSON array per field), a 1 000-notebook index decodes in ~3.5 ms (release, loaded M-series). If missing or corrupt (kept as `index.corrupt.json`), rebuild by scanning `Documents/Notebooks/*.nb/manifest.json` (off main, library shows progressively; folders are index-only, so a corrupt-index rebuild unfiles notebooks).
- Views: Recents (last 6 by modified, with `cover.heic` previews), covers grid (all, by folder chip), folder chips (All + folders + "+"). Search field filters by title, case/diacritic-insensitive `localizedStandardContains`, in memory, no debounce needed.
- New notebook sheet (mock §06): title, cover color (8), paper (Blank/Lined/Dotted/Grid), paper style (White/Cream/Night), A4 portrait fixed. Create → write package + index entry → push editor on page 1 in the same transaction (no interim library state).
- Management: rename, move to folder, delete (trash to `Library/Trash/`, purged after 30 days), duplicate. Context menu on covers.
- Open notebook < 150 ms (#43): index already has everything the editor needs to lay out pages (page count, page size), so the first frame is paper for every page; as soon as the manifest is read (page IDs) page 1 shows `thumbs/<id>.heic` scaled up, `DocumentStore` loads page 1's strokes (< 10 ms) and the first sharp raster (or the canvas's own render, whichever lands first) replaces the thumbnail with a 120 ms crossfade (`canvas.firstSharpTile`). Pages 2–3 load next (`PageWindow.loadOrder`). Nothing else is read until scrolled near. The index holds no page IDs, so the thumbnail can't be in the very first frame; it follows a few ms later.

## 9. PDF export

`Export` package, CoreGraphics (`UIGraphicsPDFRenderer` in app, `CGContext(consumer:mediaBox:)` in headless tests). Vector by default:

- Reuse `InkGeometry` geometry, fitted to cubics within ~4 % of the stroke width: centerlines stroked with round caps/joins in near-constant-width pieces (one piece for ballpoint/highlighter), filled outlines only where that can't work (dots, translucent varying-width ink). ≤ 10 MB per 100 dense pages (~7.7 MB for the seed-1 fixture). Photos (#157) drawn over the template as images (`imageLoader` decodes `images/<asset>.heic`), then highlighter with `.multiply` blend, then ink. Template background as vector lines/dots. Page size = notebook page size in points, one PDF page per notebook page.
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
| `text.secondary` | `#666970` (mock `#8A8C92`, darkened to 4.5:1 for #45) | `#A9ABB2` |
| `template.line` | `rgba(30,33,41,.16)` | `rgba(255,255,255,.09)` |
| Palette (11) | `#1E2129 #5D6470 #2C4FD6 #1E8E6E #D2402F #E07A1F #7E4FD8 #C2457E #0FA3B1 #8D6E4C #E8B800` | adapted (below) |
| Covers (8) | `#8E9F87 #C07F5E #2F3B57 #D9C9AC #6B4A5E #3B3C40 #9DB4C9 #E3A5A0` | same |

Geometry: capsule height 52, radius 26, blur 24 + saturate 180 %; tool button 44×40 r20, active = 8 % ink tint + 4 pt dot in the current color; quick-color swatch 22 pt, selected ring 2 pt paper + 3.5 pt color; page radius 4, shadow `0 12 40 -12 rgba(40,30,10,.18)`; pages-overview thumb 176×228 r6, selected ring 3 pt blue; cover 150×196, radius 5/12 (spine); popover 328 w r24. Type: SF Pro for UI, **Instrument Serif** (OFL, bundled) for notebook titles and the pages-overview heading. Caveat in the mocks is stand-in handwriting; not shipped.

**Accessibility (#45).** Chrome geometry scales with Dynamic Type by `DynamicTypeSize.chromeScale` (1 up to the default size, 1.5 at AX1) and the app caps text at AX1 (`DynamicTypeSize.chromeLimit`); chrome fonts are text styles or `scaledFont(size:)`. Secondary text meets 4.5:1. The canvas is one VoiceOver element, "Drawing area" (page + stroke count as value, three-finger swipe turns pages, undo/redo/show pages as custom actions). Chrome reads nav → tools → pages → page pill on every dock; focus mode is only entered on request; Reduce Motion swaps focus mode without a morph or fade. `AccessibilityTests` runs Xcode's accessibility audit on the library and editor.

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

- `Perf` package: `Signpost` enum wrapping `OSSignposter` with fixed names (`launch.firstFrame`, `notebook.open`, `canvas.firstSharpTile`, `canvas.frame`, `tile.render`, `stroke.commit`, `doc.checkpoint`, `thumb.render`, `export.pdf`, `page.image.render`). MetricKit subscriber logs launch/hang/animation payloads to a local JSON for inspection.
- Debug HUD (debug builds, 3-finger triple-tap): frame time, hitch count, ink latency p50/p95, resident page images MB + render queue depth (`page img`), WAL size.
- `PerfTests` target: `measure(metrics:)` with `XCTApplicationLaunchMetric`, `XCTOSSignpostMetric`, `XCTCPUMetric`, `XCTMemoryMetric` over `Fixtures/` notebooks (1, 10, 100, 300 pages). Baselines checked in per simulator model. CI gate: fail on > 10 % regression vs baseline. Simulator numbers are for *relative* regression only; absolute budgets are verified on device, on a checklist in the PR template.
- Fixture generator (`Packages/Fixtures`, kept out of `Document` so the app-linked package carries no dev code and the generator can later also depend on `Library` for a matching index): `make fixtures` writes `Fixtures/{1,10,100,300}-pages.nb` (gitignored; regenerate, never commit). Deterministic from `--seed` (byte-identical packages: IDs from a synthetic clock + seeded stream, fixed dates). ~400 strokes/page, ~62 samples/stroke: cursive words in lines with word gaps, i-dots/t-bars, headings, bullets, highlighter swipes, box-and-arrow diagrams, Cornell cues; mixed templates and pens. 300 pages (181 MB) in < 1.5 s release. `FixtureGen` is a library, so simulator perf tests can generate in-process.

## 13. Testing, CI, lint

- Unit (headless, `swift test` per package): codec round-trip + fuzz, WAL replay, migrations, geometry (tessellation invariants, hit-tests), eraser split, lasso selection, `EditStack` inverse properties, library search, PDF output page count and bbox.
- Renderer snapshot tests (simulator): render fixture pages via `engine.render` and compare to golden PNGs with a perceptual tolerance; same fixtures through both engines to keep the PencilKit adapter honest.
- UI smoke (simulator, `XCUITest`): launch → create notebook → draw a stroke (XCUI drag) → back → cover updated → export produces a PDF.
- Perf tests (§12).
- GitHub Actions on a self-hosted macOS runner (the dev Mac, single lane, so jobs are serial):
  1. `ci` (PRs, one job so nothing queues between steps): `swiftformat --lint .` + `swiftlint --strict`; `swift test` per headless package; `xcodegen generate` → `xcodebuild test` on an iPad simulator with `-skip-testing:NotespaceUITests` (renderer, PencilKit and Metal package tests). ~6 min.
  2. `ui` (nightly, `workflow_dispatch`, PRs touching `App/**`, `Tests/UITests/**`, `project.yml`): the XCUI tests alone, with one retry (gesture flakes).
  3. `perf` (nightly + label `run-perf`): `PerfTests`, compares against baselines, posts a summary comment.
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
8. **Toolbar**: dynamic — floats top by default, drag to dock top/bottom/left/right, pinch-in to focus mode, chevron or pinch-out to leave (§7).

## 16. Future (not Day 0, designed for)

iCloud sync (ship the `PageEdit` journal; IDs and `rev`s already in place). Handwriting search/OCR (Vision over `engine.render` output, index in `Library`). Infinite canvas (page layout is already frame-based; one unbounded page). Text boxes/shapes (new item kinds alongside `Stroke` and `PageImage`, #157). Photo rotate/crop, other photo sources (Files, camera, paste, drag-drop), cleanup of image assets no placement references. Collaboration (journal + IDs again).

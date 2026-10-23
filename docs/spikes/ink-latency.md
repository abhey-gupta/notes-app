# Spike: ink latency, PencilKit vs Metal (#16)

Status: **prototype built, waiting for device numbers.** Simulator runs only show that the app works. Simulator latency numbers are meaningless and are not reported here.

Prototype: `spikes/ink-latency/` on branch `spike/16-ink-latency` (draft PR, never merged).

## Question

Can our own Metal ink engine get within one 120 Hz frame (8.3 ms) of PencilKit's pen-to-pixel latency on the same iPad? ARCHITECTURE.md §3 bets that it can.

## What the prototype does

One app with three screens, switched by the segmented control at the top:

| Screen | What it is |
|---|---|
| **PencilKit** | Stock `PKCanvasView`, `.pen` ink at 3 pt, white background. No custom code in the ink path. |
| **Metal** | Minimal custom engine: a `CAMetalLayer` view (`maximumDrawableCount = 2`, `framebufferOnly`, opaque). It draws **inside each touch event**, not on the display link. It uses `coalescedTouches` for samples and `predictedTouches` as a tail that the next event throws away. A `CADisplayLink` with `preferredFrameRateRange` 120/120/120 runs while the pen is down so the display stays at 120 Hz. Geometry comes from `InkGeometry` (`Centerline` → `StrokeTessellator`, fountain profile, 3 pt). The shader uses the `StrokeVertex` coverage formula with round caps and flat color. |
| **PencilKit · 100 pages** | One tall `PKCanvasView` with 100 A4-proportioned pages and one `PKDrawing`. Buttons fill it with 0, 40 or 400 synthetic strokes per page (~60 points each). The label shows `phys_footprint` and how long the build and `drawing =` assignment took. |

The Metal screen measures **`UITouch.timestamp` → `MTLDrawable.presentedTime`** for every frame it draws. `UITouch.timestamp` is the newest coalesced touch in that frame, and `presentedTime` comes from `addPresentedHandler`. Both clocks are `CACurrentMediaTime` (mach absolute time) seconds, so the difference is the latency with no conversion. Frames that are dropped or never presented (`presentedTime == 0`) are counted separately and left out of the stats. The screen shows live p50/p95/n for two buckets, "Straight lines" and "Fast scribbles". You pick the bucket before drawing. The Perf debug HUD (3-finger triple-tap) also shows frame time, hitches and the current bucket's p50/p95.

What the in-app number does **not** include: digitizer and touch processing before `UITouch.timestamp`, and display scan-out after `presentedTime`. Prediction is also invisible to it, even though prediction cuts *perceived* lag. That is why the slow-motion video is the number that decides, and why the in-app number is only a Metal-side cross-check. PencilKit has no hook for present timestamps, so the video is the only way to measure it.

## Run it on your iPad

Requirements: iPad with ProMotion (120 Hz) and Apple Pencil, Xcode 27.1, `brew install xcodegen`.

1. Generate and open the project:
   ```
   cd spikes/ink-latency
   xcodegen generate
   open InkLatencySpike.xcodeproj
   ```
2. Signing (once): select the **InkLatencySpike** target, open **Signing & Capabilities**, check **Automatically manage signing** and set Team to **7SBKK4A99S**. If Xcode says "No account for team", add your Apple ID under **Xcode › Settings › Accounts** first. Bundle ID: `com.abhey.notespace.spike.inklatency`.
3. Connect the iPad by cable (or the same Wi-Fi with "Connect via network"). Choose it as the run destination. If prompted, turn on **Settings › Privacy & Security › Developer Mode** on the iPad and restart it.
4. Press **Run** (⌘R). The scheme's Run action is already **Release**: latency from an unoptimized build means nothing. The first launch may say "Untrusted Developer". In that case, go to **Settings › General › VPN & Device Management**, trust your developer certificate and launch again.
5. Before measuring: full brightness, Low Power Mode **off**, charger unplugged or not (note which), no other apps running, and **Settings › Accessibility › Motion › Limit Frame Rate off**.

### Method A: in-app (Metal only)

1. Open the **Metal** screen. Select **Straight lines** and tap **Reset stats**.
2. Draw ~30 straight strokes at a steady, brisk speed, each ~10 cm long.
3. Select **Fast scribbles** and tap **Reset stats** (this resets only the selected bucket). Scribble fast in tight loops for ~20 s.
4. Tap **Copy results** and paste the text into the table below (it is also written to the device log with the `com.abhey.notespace.spike` subsystem).
5. Repeat once more on a cleared canvas (**Clear ink**) and keep the worse run.

### Method B: 240 fps slow-motion video (both engines, decisive)

1. Mount an iPhone (Camera › Slo-Mo at **240 fps**, 1080p) above the iPad so it sees the Pencil tip and the ink. Use bright, even light, and turn off HDR and auto-exposure flicker (lock exposure by long-pressing).
2. For each engine (**PencilKit** screen, then **Metal** screen), record:
   - 10 **straight lines**: steady medium-fast strokes, left to right.
   - 10 s of **fast scribbles**.
3. Measure in a frame-steppable player (QuickTime: arrow keys; one frame = 4.17 ms):
   - **Pen-down latency**: count frames from the first frame where the tip touches the glass to the first frame where ink appears under it. × 4.17 ms.
   - **In-motion latency**: on a frame mid-stroke, measure the gap between the tip and the end of the ink (mm, using a ruler in frame or the iPad's known width). Measure the tip's speed over ±5 frames (mm per frame × 240). Latency = gap ÷ speed. Take 10 frames per clip.
4. Record p50 and p95 over the samples for each cell. With ~10–20 samples per cell, "p95" is effectively the second-worst. That is fine for a go/no-go call.

### 100 stacked pages (PencilKit)

On **PencilKit · 100 pages**:

1. Note the footprint while empty.
2. Tap **Fill 40/page**, then **Fill 400/page** (~4k and ~40k strokes). Note the build/assign time and the footprint after each.
3. Fling-scroll from top to bottom and back. Watch the HUD's hitch count and fps (3-finger triple-tap) and note any blank tiles or stalls. Draw on page ~90 and judge pen latency subjectively.
4. Note whether the app gets jetsam-killed (Xcode reports "Terminated due to memory issue").

## Results (fill in on device)

Device: `__________` (model, chip, iPadOS version) · Pencil: `__________` · Date: `__________`

### Pen-to-pixel latency

| Engine | Gesture | In-app p50 (ms) | In-app p95 (ms) | Video p50 (ms) | Video p95 (ms) | Notes |
|---|---|---|---|---|---|---|
| PencilKit | Straight lines | n/a | n/a | | | |
| PencilKit | Fast scribbles | n/a | n/a | | | |
| Metal | Straight lines | | | | | |
| Metal | Fast scribbles | | | | | |
| **Δ Metal − PencilKit** | Straight lines | n/a | n/a | | | |
| **Δ Metal − PencilKit** | Fast scribbles | n/a | n/a | | | |

Pen-down latency (video, frames × 4.17 ms): PencilKit `____` ms · Metal `____` ms.

Dropped/unpresented Metal frames: `____` of `____`.

### PencilKit, 100 stacked pages

| Fill | Strokes | Build (ms) | Assign `drawing` (ms) | Footprint (MB) | Scroll (fps / hitches) | Notes |
|---|---|---|---|---|---|---|
| Empty | 0 | n/a | n/a | | | |
| 40 / page | 4 000 | | | | | |
| 400 / page | 40 000 | | | | | |

## Decision rule

Use the **video** numbers, p50 and p95, for both gestures:

- **Metal ships** if Metal's latency is **within 8.3 ms (one 120 Hz frame) of PencilKit** in every row (Δ ≤ 8.3 ms). The custom engine (#19) goes ahead as planned. The PencilKit adapter (#18) stays the fallback and baseline.
- **Otherwise** the PencilKit adapter becomes P0: it ships behind the `InkEngine` seam, and #19 is re-scoped to closing the gap (or to non-latency work such as tiles and rendering) before it can replace PencilKit.

The in-app Metal number is a sanity check. If it reads well under 16 ms p95 while the video shows a large gap, the time is going into input or scan-out, not our render path.

Decision: `__________` (fill in with the numbers above and close #16).

## Known prototype shortcuts

- All committed strokes are redrawn on every event (flat buffer, one draw per stroke), and the live stroke is re-tessellated from scratch each event. That is fine for a few hundred strokes. Use **Clear ink** between runs.
- No tile cache, no page background, flat color, fountain profile only.
- The shader is compiled at runtime (`makeLibrary(source:)`), so the spike builds without the optional Metal Toolchain download. This does not affect per-frame latency.
- `nextDrawable()` can block when both drawables are in flight. That is the expected cost of `maximumDrawableCount = 2`, and it shows up in the numbers.

Closes #

## Device budget checklist

Simulator perf is relative only (`run-perf` label / nightly gate). If this PR touches launch, open, ink,
scroll or rendering, check the absolute budgets on a real iPad (Release build, docs/SCOPE.md):

- [ ] Cold launch → library < 400 ms (signpost `launch.firstFrame`)
- [ ] Open notebook → first page inked < 150 ms (`notebook.open` → `canvas.firstSharpTile`)
- [ ] Ink latency at hardware floor, 120 Hz (debug HUD p50/p95)
- [ ] Scroll/zoom 120 Hz, no hitches on the 300-page fixture (Instruments Hitches)
- [ ] N/A: no perf-sensitive change

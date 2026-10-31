<img src="assets/icon.svg" width="64" height="64" alt="">

# Notespace

Ultra-fast, minimal, beautiful handwritten notes for iPad.

- Scope and perf budgets: [`docs/SCOPE.md`](docs/SCOPE.md)
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Mockups: [`design/mockups-v1.html`](design/mockups-v1.html), sync: [`design/mockups-sync.html`](design/mockups-sync.html)
- Tracker: GitHub Issues, milestone "Day 0"

## Requirements

- Xcode 27.1 (iOS 27.1 SDK, Swift 6.4), deployment target iPadOS 26.0
- `brew install xcodegen swiftformat swiftlint xcbeautify`
- iPad simulator named `iPad Pro 13 (M5)` (override with `SIM="..."`)

## Commands

```
make gen            # generate Notespace.xcodeproj from project.yml (not committed)
make open           # gen + open in Xcode
make build          # build app for the iPad simulator
make ipa            # unsigned Release build/Notespace.ipa for sideloading
make test           # app UI tests + every package's tests on the simulator
make test-unit      # same without the UI tests (the PR gate)
make test-ui        # UI tests only
make test-packages  # headless packages via `swift test` (no simulator)
make perf           # perf tests (Release), no gate
make perf-gate      # perf tests vs Tests/PerfTests/baselines.json, fails on > 10 % regression
make perf-baseline  # rewrite this simulator model's baselines
make fixtures       # Fixtures/{1,10,100,300}-pages.nb, deterministic (notespace-fixtures --help)
make lint / format
```

CI: GitHub Actions on a self-hosted runner on the dev Mac (`runs-on: [self-hosted, macOS, xcode27]`), service in `~/actions-runner/notespace` (`./svc.sh status/start/stop`). PR gate `ci.yml`: one job (lint, headless packages, simulator tests without UI tests, ~6 min). `ui.yml`: UI tests nightly, on demand, and on PRs touching `App/**`, `Tests/UITests/**` or `project.yml`. Perf gate runs nightly and on PRs labeled `run-perf`; it comments the summary on the PR.

Release: push a `v*` tag → `release.yml` builds the unsigned `.ipa` and attaches it to a GitHub release (manual run: artifact only). Install with AltStore/SideStore, which re-sign it with a free Apple ID (7-day expiry, refreshed over Wi-Fi by AltServer/SideStore).

## Perf gate

`NotespacePerfTests` (Release): cold launch, `launch.firstFrame` with 200 notebooks, `notebook.open` on the
100-page fixture, memory with 1 000 notebooks. The test runner builds the fixture libraries with `FixtureGen`
(cached per simulator) and points the app at them with `-libraryRoot` (DEBUG and simulator builds only).
`scripts/perf-gate.sh` takes the median of `PERF_ITERATIONS` (5) runs after a warm-up, compares with the
baseline for the simulator model, and re-runs regressed tests once (`PERF_RETRIES`), keeping the better
median, before failing. Tolerance: `tolerance` (0.10) in `baselines.json`, per metric in `overrides`
(`{"<metric id>": {"tolerance": 0.15, "slack": 0.002}}`, slack in the metric's unit). Summary:
`build/perf/summary.md`.

Simulator numbers are relative only, and the shared Mac is noisy. Refresh baselines on a quiet machine
(no agents, CI runner stopped: `~/actions-runner/notespace/svc.sh stop`, other simulators shut down):

```
make perf-baseline SIM="iPad Pro 13 (M5)" PERF_ITERATIONS=10
make perf-gate SIM="iPad Pro 13 (M5)"   # should pass; commit Tests/PerfTests/baselines.json
```

Refresh after intended perf changes, or when the Xcode/simulator runtime changes.

## Layout

`App/` thin SwiftUI shell · `Packages/` local Swift packages (see ARCHITECTURE.md §2) · `Tests/` UI + perf tests.

<img src="assets/icon.svg" width="64" height="64" alt="">

# Notespace

Ultra-fast, minimal, beautiful handwritten notes for iPad.

- Scope and perf budgets: [`docs/SCOPE.md`](docs/SCOPE.md)
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Mockups: [`design/mockups-v1.html`](design/mockups-v1.html)
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
make test           # app UI tests + every package's tests on the simulator
make test-packages  # headless packages via `swift test` (no simulator)
make perf           # launch perf tests (Release)
make lint / format
```

## Layout

`App/` thin SwiftUI shell · `Packages/` local Swift packages (see ARCHITECTURE.md §2) · `Tests/` UI + perf tests.

SIM ?= iPad Pro 13 (M5)
DEST := platform=iOS Simulator,name=$(SIM)
HEADLESS := InkModel InkGeometry Document Library Tools Export Fixtures
XCB := $(shell command -v xcbeautify >/dev/null && echo "| xcbeautify" )

.PHONY: gen lint format test-packages build test perf perf-gate perf-baseline fixtures open clean

gen:
	xcodegen generate --quiet

lint:
	swiftformat --lint .
	swiftlint --strict --quiet

format:
	swiftformat .
	swiftlint --fix --quiet

test-packages:
	@set -e; for p in $(HEADLESS); do echo "▸ $$p"; swift test --quiet --package-path Packages/$$p; done

build: gen
	set -o pipefail; xcodebuild build -project Notespace.xcodeproj -scheme Notespace -destination '$(DEST)' $(XCB)

# No post-failure diagnostics (can hang 10 min); retry flaky UI gestures once.
TESTFLAGS := -collect-test-diagnostics never -retry-tests-on-failure -test-iterations 2

test: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme Notespace -destination '$(DEST)' $(TESTFLAGS) $(XCB)

perf: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme NotespacePerf -destination '$(DEST)' $(XCB)

# Perf regression gate vs Tests/PerfTests/baselines.json (median of PERF_ITERATIONS, > 10 % fails).
# perf-baseline rewrites this simulator model's baselines: run on a quiet machine (README).
PERF_ITERATIONS ?= 5
PERF_ENV = SIM='$(SIM)' PERF_ITERATIONS=$(PERF_ITERATIONS)

perf-gate: gen
	$(PERF_ENV) scripts/perf-gate.sh gate

perf-baseline: gen
	$(PERF_ENV) scripts/perf-gate.sh baseline

# Deterministic 1/10/100/300-page notebooks in Fixtures/ (gitignored), ARCHITECTURE.md §12.
FIXTURE_PAGES ?= 1 10 100 300
FIXTURE_SEED ?= 1
FIXTURES_PKG := Packages/Fixtures

fixtures:
	swift build -c release --quiet --package-path $(FIXTURES_PKG) --product notespace-fixtures
	@set -e; bin=$$(swift build -c release --package-path $(FIXTURES_PKG) --show-bin-path); \
	for n in $(FIXTURE_PAGES); do $$bin/notespace-fixtures --pages $$n --seed $(FIXTURE_SEED) --out Fixtures --force; done

open: gen
	open Notespace.xcodeproj

clean:
	rm -rf Notespace.xcodeproj DerivedData Packages/*/.build Fixtures

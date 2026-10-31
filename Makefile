SIM ?= iPad Pro 13 (M5)
DEST := platform=iOS Simulator,name=$(SIM)
HEADLESS := InkModel InkGeometry Document Library Sync Tools Editing Export Fixtures Canvas
XCB := $(shell command -v xcbeautify >/dev/null && echo "| xcbeautify" )

.PHONY: gen lint format test-packages build device ipa test test-unit test-ui perf perf-device perf-gate perf-baseline fixtures open clean

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

# Release test build onto a connected iPad (DEVICE=<udid>) with the DEV-badged icon (AppIconDev.icon).
DEVICE ?= 00008103-0011486002D1001E
device: gen
	set -o pipefail; xcodebuild build -project Notespace.xcodeproj -scheme Notespace -configuration Release \
		-destination 'id=$(DEVICE)' -derivedDataPath build/device -allowProvisioningUpdates DEVELOPMENT_TEAM=YXJ29YJZ96 \
		ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDev $(XCB)
	xcrun devicectl device install app --device $(DEVICE) build/device/Build/Products/Release-iphoneos/Notespace.app
	xcrun devicectl device process launch --device $(DEVICE) com.abhey.notespace

# Unsigned Release .ipa + dSYM zip for sideloading (AltStore/SideStore re-sign it with your Apple ID).
# VERSION/BUILD override MARKETING_VERSION/CURRENT_PROJECT_VERSION (release.yml: tag, run number).
IPA_DD := build/ipa
IPA_VERSION := $(if $(VERSION),MARKETING_VERSION=$(VERSION)) $(if $(BUILD),CURRENT_PROJECT_VERSION=$(BUILD))

ipa: gen
	set -o pipefail; xcodebuild build -project Notespace.xcodeproj -scheme Notespace -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath $(IPA_DD) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= $(IPA_VERSION) $(XCB)
	rm -rf $(IPA_DD)/Payload build/Notespace.ipa build/Notespace.dSYM.zip
	mkdir -p $(IPA_DD)/Payload
	cp -R $(IPA_DD)/Build/Products/Release-iphoneos/Notespace.app $(IPA_DD)/Payload/
	cd $(IPA_DD) && zip -qry ../Notespace.ipa Payload
	cd $(IPA_DD)/Build/Products/Release-iphoneos && zip -qry ../../../../Notespace.dSYM.zip Notespace.app.dSYM
	@echo "▸ build/Notespace.ipa, build/Notespace.dSYM.zip"

# No post-failure diagnostics (can hang 10 min); retry flaky UI gestures once.
TESTFLAGS := -collect-test-diagnostics never -retry-tests-on-failure -test-iterations 2
# Always on, even with TESTFLAGS overridden: a hung test (PencilKit can deadlock in the simulator)
# fails after 5-10 min instead of blocking the run forever. Swift Testing suites also set .timeLimit.
TIMEOUTS := -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 600

test: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme Notespace -destination '$(DEST)' $(TESTFLAGS) $(TIMEOUTS) $(XCB)

# PR gate: everything in the scheme but the XCUI tests (simulator-only package tests: InkEnginePencilKit, InkEngineMetal).
test-unit: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme Notespace -destination '$(DEST)' \
		-skip-testing:NotespaceUITests -collect-test-diagnostics never $(TIMEOUTS) $(XCB)

# XCUI tests only (slow, gesture-flaky): nightly and on PRs that touch the app (ui.yml).
test-ui: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme Notespace -destination '$(DEST)' \
		-only-testing:NotespaceUITests $(TESTFLAGS) $(TIMEOUTS) $(XCB)

perf: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme NotespacePerf -destination '$(DEST)' $(XCB)

# #44 stress pass on a connected device (DEVICE=<udid>): Release + PERF_FIXTURES, 300-page fixture.
perf-device: gen
	set -o pipefail; xcodebuild test -project Notespace.xcodeproj -scheme NotespacePerf -destination 'id=$(DEVICE)' \
		-allowProvisioningUpdates -only-testing:NotespacePerfTests/CanvasStressPerfTests \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) PERF_FIXTURES' -resultBundlePath build/perf-device.xcresult $(XCB)

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

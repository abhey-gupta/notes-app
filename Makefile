SIM ?= iPad Pro 13 (M5)
DEST := platform=iOS Simulator,name=$(SIM)
HEADLESS := InkModel InkGeometry Document Library Tools Export
XCB := $(shell command -v xcbeautify >/dev/null && echo "| xcbeautify" )

.PHONY: gen lint format test-packages build test perf open clean

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

open: gen
	open Notespace.xcodeproj

clean:
	rm -rf Notespace.xcodeproj DerivedData Packages/*/.build

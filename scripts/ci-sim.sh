#!/bin/sh
# Ensure the CI simulator exists; print its name.
set -eu
NAME="${1:-CI-iPad}"
if ! xcrun simctl list devices available | grep -q "$NAME ("; then
  RUNTIME=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')
  xcrun simctl create "$NAME" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB "$RUNTIME" >/dev/null
fi
echo "$NAME"

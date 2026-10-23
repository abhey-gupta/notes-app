#!/bin/sh
# Ensure the CI simulator exists; print its name.
set -eu
NAME="${1:-CI-iPad}"
DEVTYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
if ! xcrun simctl list devices available | grep -q "$NAME ("; then
  # Newest available iOS runtime that supports the device type.
  RUNTIME=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
dt = sys.argv[1]
rs = [r for r in json.load(sys.stdin)["runtimes"]
      if r["platform"] == "iOS" and r["isAvailable"]
      and any(d["identifier"] == dt for d in r.get("supportedDeviceTypes", []))]
print(rs[-1]["identifier"])' "$DEVTYPE")
  xcrun simctl create "$NAME" "$DEVTYPE" "$RUNTIME" >/dev/null
fi
echo "$NAME"

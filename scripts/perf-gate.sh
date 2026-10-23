#!/bin/bash
# Perf regression gate (ARCHITECTURE.md §12). Runs NotespacePerfTests (Release) on a simulator, takes the
# median of each metric, compares with Tests/PerfTests/baselines.json for the simulator's model.
#
#   scripts/perf-gate.sh gate      fail on > tolerance regression (default 10 %, per-metric overrides)
#   scripts/perf-gate.sh baseline  rewrite this model's baselines from a fresh run
#
# Env: SIM (simulator name, required), PERF_ITERATIONS (measured runs per test, default 5),
# PERF_RETRIES (gate: re-run regressed tests and keep the better median, default 1),
# PERF_OUT (default build/perf). Summary: $PERF_OUT/summary.md (+ $GITHUB_STEP_SUMMARY).
set -euo pipefail

MODE="${1:-gate}"
: "${SIM:?set SIM to a simulator name}"
ITERATIONS="${PERF_ITERATIONS:-5}"
RETRIES="${PERF_RETRIES:-1}"
OUT="${PERF_OUT:-build/perf}"
BASELINES=Tests/PerfTests/baselines.json
PY=(/usr/bin/python3 -I "$(cd "$(dirname "$0")" && pwd)/perf_gate.py")

# Simulator → UDID, model (device type), runtime.
read -r UDID MODEL RUNTIME STATE < <(xcrun simctl list devices available -j | /usr/bin/python3 -I -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == sys.argv[1]:
            model = d["deviceTypeIdentifier"].rsplit(".", 1)[-1]
            os, _, version = runtime.rsplit(".", 1)[-1].partition("-")
            print(d["udid"], model, os + "-" + version.replace("-", "."), d["state"])
            sys.exit(0)
sys.exit("no available simulator named " + sys.argv[1])' "$SIM")

# Leave the simulator as we found it.
if [ "$STATE" != "Booted" ]; then
  trap 'xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT
fi

rm -rf "$OUT"
mkdir -p "$OUT"
XCB=(cat)
command -v xcbeautify >/dev/null && XCB=(xcbeautify --quiet)
DEST="id=$UDID"
COMMON=(-project Notespace.xcodeproj -scheme NotespacePerf -destination "$DEST")

echo "▸ build-for-testing ($MODEL, $RUNTIME)"
xcodebuild build-for-testing "${COMMON[@]}" 2>&1 | "${XCB[@]}"

# run <n> [-only-testing:… …]: one test pass → $OUT/run<n>.json. Test failures are reported by the gate
# (missing metrics), so keep going.
run() {
  local n=$1
  shift
  echo "▸ perf run $n ($ITERATIONS iterations)"
  TEST_RUNNER_PERF_ITERATIONS="$ITERATIONS" xcodebuild test-without-building "${COMMON[@]}" \
    -collect-test-diagnostics never -resultBundlePath "$OUT/run$n.xcresult" "$@" > "$OUT/run$n.log" 2>&1 ||
    echo "run$n" >> "$OUT/test-failures"
  grep -E "measured \[|error:|Test Case .*(passed|failed)" "$OUT/run$n.log" | sed -E 's/, baselineName.*//' || true
  "${PY[@]}" extract "$OUT/run$n.xcresult" "$OUT/run$n.json"
}

run 1
RUNS=("$OUT/run1.json")
"${PY[@]}" merge "$OUT/metrics.json" "${RUNS[@]}"

if [ "$MODE" = baseline ]; then
  if [ -s "$OUT/test-failures" ]; then
    echo "✗ perf tests failed, baselines unchanged (see $OUT/run1.log)" >&2
    exit 1
  fi
  "${PY[@]}" baseline "$OUT/metrics.json" "$BASELINES" "$MODEL" "$RUNTIME" "$OUT/summary.md"
  exit 0
fi

status=0
for ((attempt = 1; ; attempt++)); do
  if "${PY[@]}" gate "$OUT/metrics.json" "$BASELINES" "$MODEL" "$OUT/summary.md" \
    --failing "$OUT/failing.txt" --runtime "$RUNTIME" > /dev/null; then
    status=0
    break
  else
    status=$?
  fi
  if [ "$attempt" -gt "$RETRIES" ] || [ ! -s "$OUT/failing.txt" ]; then
    break
  fi
  # Noise check: a real regression survives a re-run; a load spike doesn't.
  only=()
  while read -r test; do only+=("-only-testing:NotespacePerfTests/${test%()}"); done < "$OUT/failing.txt"
  echo "▸ regression in $(tr '\n' ' ' < "$OUT/failing.txt")— re-running to rule out noise"
  run $((attempt + 1)) "${only[@]}"
  RUNS+=("$OUT/run$((attempt + 1)).json")
  "${PY[@]}" merge "$OUT/metrics.json" "${RUNS[@]}"
done

cat "$OUT/summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$status"

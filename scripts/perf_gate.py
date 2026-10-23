#!/usr/bin/env python3
"""Perf gate helpers for scripts/perf-gate.sh (ARCHITECTURE.md §12).

  perf_gate.py extract <xcresult> <out.json>
      Per-test metrics from `xcresulttool get test-results metrics`: {test: {metric_id: {...}}}.
  perf_gate.py merge <out.json> <run.json>...
      Best-of: per metric keeps the run with the better median (retries only replace noisy runs).
  perf_gate.py gate <run.json> <baselines.json> <device> <summary.md> [--failing <tests.txt>] [--runtime <rt>]
      Compares medians with the device's baselines; exit 1 on regression or missing metric.
  perf_gate.py baseline <run.json> <baselines.json> <device> <runtime> <summary.md>
      Rewrites the device's baselines (tolerances and other devices are kept).
"""

import json
import statistics
import subprocess
import sys
from datetime import date

DEFAULT_TOLERANCE = 0.10


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        if default is None:
            raise
        return default


def dump(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")


def smaller_is_better(metric):
    return "larger" not in metric.get("polarity", "prefers smaller")


def extract(xcresult, out):
    raw = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", xcresult, "--compact"],
        check=True, capture_output=True, text=True,
    ).stdout
    runs = {}
    for test in json.loads(raw):
        name = test["testIdentifier"]
        for run in test["testRuns"]:
            for m in run["metrics"]:
                values = m["measurements"]
                if not values:
                    continue
                runs.setdefault(name, {})[m["identifier"]] = {
                    "name": m["displayName"],
                    "unit": m["unitOfMeasurement"],
                    "polarity": m.get("polarity", "prefers smaller"),
                    "values": values,
                    "median": statistics.median(values),
                }
    dump(runs, out)


def merge(out, paths):
    merged = {}
    for path in paths:
        for test, metrics in load(path).items():
            for mid, m in metrics.items():
                best = merged.setdefault(test, {}).get(mid)
                if best is None:
                    better = True
                elif smaller_is_better(m):
                    better = m["median"] < best["median"]
                else:
                    better = m["median"] > best["median"]
                if better:
                    merged[test][mid] = m
    dump(merged, out)


def fmt(value, unit):
    if unit == "s":
        return f"{value * 1000:.1f} ms"
    if unit == "kB":
        return f"{value / 1024:.1f} MB"
    return f"{value:.3g} {unit}"


def short(name):
    return name.replace("Duration ", "").replace("ApplicationFirstFramePresentationResponsive", "launch → responsive")


def gate(run_path, baselines_path, device, summary_path, failing_path=None, runtime=None):
    run = load(run_path)
    config = load(baselines_path, {})
    overrides = config.get("overrides", {})
    default_tol = config.get("tolerance", DEFAULT_TOLERANCE)
    base = config.get("devices", {}).get(device)
    rows, regressions, failing = [], 0, set()
    if base is None:
        lines = [f"### Perf gate: no baselines for `{device}`", "",
                 "Run `make perf-baseline SIM=…` on a quiet machine and commit `Tests/PerfTests/baselines.json`."]
        write_summary(summary_path, lines)
        return 1
    for test, metrics in sorted(base["tests"].items()):
        for mid, b in sorted(metrics.items()):
            o = overrides.get(mid, {})
            tol, slack = o.get("tolerance", default_tol), o.get("slack", 0)
            m = run.get(test, {}).get(mid)
            label = f"`{test.split('/')[-1].rstrip('()')}` {short(b['name'])}"
            if m is None:
                regressions += 1
                failing.add(test)
                rows.append(f"| {label} | {fmt(b['median'], b['unit'])} | — | — | ±{tol:.0%} | ❌ missing |")
                continue
            delta = m["median"] / b["median"] - 1 if b["median"] else 0
            if smaller_is_better(b):
                regressed = m["median"] > b["median"] * (1 + tol) + slack
                improved = m["median"] < b["median"] * (1 - tol) - slack
            else:
                regressed = m["median"] < b["median"] * (1 - tol) - slack
                improved = m["median"] > b["median"] * (1 + tol) + slack
            status = "❌ regressed" if regressed else ("🟢 improved" if improved else "✅")
            if regressed:
                regressions += 1
                failing.add(test)
            spread = f"{fmt(min(m['values']), m['unit'])}–{fmt(max(m['values']), m['unit'])}"
            rows.append(f"| {label} | {fmt(b['median'], b['unit'])} | {fmt(m['median'], m['unit'])} ({spread}, n={len(m['values'])}) "
                        f"| {delta:+.1%} | ±{tol:.0%} | {status} |")
    for test, metrics in sorted(run.items()):
        for mid, m in sorted(metrics.items()):
            if mid not in base["tests"].get(test, {}):
                rows.append(f"| `{test.split('/')[-1].rstrip('()')}` {short(m['name'])} | — | {fmt(m['median'], m['unit'])} | — | — | ⚪ no baseline |")
    verdict = f"❌ {regressions} regression(s)" if regressions else "✅ pass"
    ran_on = f", ran on {runtime}" if runtime and runtime != base.get("runtime") else ""
    lines = [
        f"### Perf gate: {verdict}",
        "",
        f"Simulator `{device}` (baseline {base.get('runtime', '?')}, recorded {base.get('recorded', '?')}{ran_on}). "
        "Medians; relative signal only, absolute budgets are checked on device.",
        "",
        "| Metric | Baseline | Median (range) | Δ | Limit | |",
        "|---|---|---|---|---|---|",
        *rows,
    ]
    write_summary(summary_path, lines)
    if failing_path:
        with open(failing_path, "w") as f:
            f.write("".join(f"{t}\n" for t in sorted(failing)))
    return 1 if regressions else 0


def baseline(run_path, baselines_path, device, runtime, summary_path):
    run = load(run_path)
    config = load(baselines_path, {})
    config.setdefault("tolerance", DEFAULT_TOLERANCE)
    config.setdefault("overrides", {})
    tests = {
        test: {mid: {"name": m["name"], "unit": m["unit"], "polarity": m["polarity"], "median": float(f"{m['median']:.6g}")}
               for mid, m in metrics.items()}
        for test, metrics in run.items()
    }
    config.setdefault("devices", {})[device] = {"runtime": runtime, "recorded": date.today().isoformat(), "tests": tests}
    dump(config, baselines_path)
    rows = [
        f"| `{t.split('/')[-1].rstrip('()')}` {short(m['name'])} | {fmt(m['median'], m['unit'])} | "
        f"{fmt(min(run[t][mid]['values']), m['unit'])}–{fmt(max(run[t][mid]['values']), m['unit'])} |"
        for t, ms in sorted(tests.items()) for mid, m in sorted(ms.items())
    ]
    write_summary(summary_path, [f"### Perf baselines recorded for `{device}` ({runtime})", "",
                                 "| Metric | Median | Range |", "|---|---|---|", *rows])
    return 0


def write_summary(path, lines):
    text = "\n".join(lines) + "\n"
    with open(path, "w") as f:
        f.write(text)
    sys.stdout.write(text)


def main(argv):
    cmd, args = argv[1], argv[2:]
    if cmd == "extract":
        extract(*args)
        return 0
    if cmd == "merge":
        merge(args[0], args[1:])
        return 0
    if cmd == "gate":
        def opt(name):
            return args[args.index(name) + 1] if name in args else None
        return gate(*args[:4], opt("--failing"), opt("--runtime"))
    if cmd == "baseline":
        return baseline(*args)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

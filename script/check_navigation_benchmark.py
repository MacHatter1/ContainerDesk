#!/usr/bin/env python3
"""Wait for the app's navigation benchmark and enforce the warm-switch budget."""
import json
from pathlib import Path
import statistics
import sys
import time

report = Path(sys.argv[1])
# Keep the full destination cycle below half a second in a debug build. This
# includes first-run-loop layout, rather than just the selection-binding cost.
budget_ms = 500
deadline = time.monotonic() + 180
while not report.exists():
    if time.monotonic() >= deadline:
        sys.exit(f"FAIL: navigation benchmark did not finish: {report}")
    time.sleep(0.25)

samples = json.loads(report.read_text())
if isinstance(samples, dict) and "error" in samples:
    sys.exit(f"FAIL: {samples['error']}")
warm = [sample for sample in samples if not sample["warmup"]]
route = [
    ("containers", "images"), ("images", "containers"),
    ("containers", "activity"), ("activity", "containers"),
    ("containers", "cleanup"), ("cleanup", "system"),
    ("system", "containers"),
]
if [(s["from"], s["to"]) for s in warm] != route * 3:
    sys.exit("FAIL: expected three complete warm navigation cycles")
for source, destination in dict.fromkeys((s["from"], s["to"]) for s in warm):
    values = [s["milliseconds"] for s in warm if (s["from"], s["to"]) == (source, destination)]
    print(f"{source:>10} -> {destination:<10} median={statistics.median(values):7.2f} ms max={max(values):7.2f} ms")
times = [s["milliseconds"] for s in warm]
print(f"Warm navigation: median={statistics.median(times):.2f} ms max={max(times):.2f} ms ({len(times)} samples)")
print(f"Report: {report}")
if max(times) >= budget_ms:
    sys.exit(f"FAIL: warm navigation exceeded {budget_ms} ms")
print(f"PASS: every warm navigation settled within {budget_ms} ms")

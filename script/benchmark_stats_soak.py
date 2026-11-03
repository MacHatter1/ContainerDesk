#!/usr/bin/env python3
"""Replay a day of live Stats updates through the production native view."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from benchmark_stats_performance import compile_benchmark


def check_checkpoint(row, range_every):
    slow = row["collection_median_ms"] >= 50 or any(
        row[key] >= 250 for key in
        ["refresh_median_ms", "interaction_p95_ms", "hover_scroll_p95_ms", "range_p95_ms", "range_max_ms"]
    )
    invalid = (row["inactive_violations"] or not row["latest_sample_correct"]
               or not row["displayed_latest_correct"] or not row["displayed_range_correct"] or row["retained_samples"] > 3_601
               or row["range_requests"] != row["tick"] // range_every
               or row["picker_evaluations"] > 2 + row["range_requests"])
    if slow or invalid:
        raise SystemExit(f"FAIL: Stats responsiveness, picker lifetime, activation, or retention budget exceeded at {row['tick']} updates")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--updates", type=int, default=86_400)
    parser.add_argument("--paired-baseline", type=Path)
    parser.add_argument("--baseline-updates", type=int, default=240)
    parser.add_argument("--range-every", type=int, default=1_024, help="Virtual collection ticks between native range changes; use 16 for a focused burst")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--assert-responsive", action="store_true")
    args = parser.parse_args()
    if args.updates < 1 or args.baseline_updates < 1 or args.range_every < 1:
        parser.error("update counts and range cadence must be positive")
    project = Path(__file__).resolve().parents[1]
    harness = project / "script/benchmarks/StatsSoakBench.swift"
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"scope": "Accelerated native Stats session with 20 containers, an hour of history, 1-second collection, 5-second presentation, hover, scrolling, range changes and inactivity. Virtual time is not wall-clock uptime or displayed FPS.",
              "started_at": datetime.now(timezone.utc).isoformat(), "machine": platform.platform(),
              "range_every": args.range_every,
              "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
              "runs": {}, "source_sha256": {}, "harness_sha256": hashlib.sha256(harness.read_bytes()).hexdigest(),
              "measurement_sha256": {str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest()
                                     for path in [Path(__file__).resolve(), project / "script/benchmark_stats_performance.py", harness]}}
    versions = ([("before", args.paired_baseline.resolve(), args.baseline_updates)] if args.paired_baseline else []) + [("after", project, args.updates)]
    with tempfile.TemporaryDirectory(prefix="containerdesk-stats-soak-") as temp:
        for version, root, updates in versions:
            binary, hashes = compile_benchmark(project, root, Path(temp), version, harness=harness, manual_refresh=True)
            report["source_sha256"][version] = hashes
            rows = []
            report["runs"][version] = rows
            with (args.output.parent / f"{args.output.stem}-{version}.jsonl").open("w") as log:
                process = subprocess.Popen([str(binary), str(updates), str(args.range_every)], stdout=subprocess.PIPE, text=True)
                try:
                    for line in process.stdout:
                        log.write(line)
                        log.flush()
                        row = json.loads(line)
                        rows.append(row)
                        if "tick" in row:
                            print(f"{version}: tick={row['tick']} collection={row['collection_median_ms']:.2f}ms refresh={row['refresh_median_ms']:.2f}ms interaction_p95={row['interaction_p95_ms']:.2f}ms footprint={row['footprint_bytes']/1_048_576:.1f}MiB", flush=True)
                            if args.assert_responsive and version == "after":
                                # Preserve a failed run and stop at its first failed
                                # checkpoint; never discard it or average it away.
                                args.output.write_text(json.dumps(report, indent=2) + "\n")
                                check_checkpoint(row, args.range_every)
                    if process.wait() != 0 or not rows or not rows[-1].get("complete"):
                        raise RuntimeError(f"{version}: native soak did not finish")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
            report["runs"][version] = rows
            args.output.write_text(json.dumps(report, indent=2) + "\n")
    after = [r for r in report["runs"]["after"] if "tick" in r]
    if args.assert_responsive:
        for row in after:
            check_checkpoint(row, args.range_every)
        if len(after) > 5:
            early = statistics.median(r["footprint_bytes"] for r in after[1:4])
            late = statistics.median(r["footprint_bytes"] for r in after[-3:])
            if late > early + 64 * 1_048_576:
                raise SystemExit("FAIL: native Stats footprint grew by more than 64 MiB after warmup")
    print(f"Report: {args.output}")


if __name__ == "__main__":
    main()

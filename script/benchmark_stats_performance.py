#!/usr/bin/env python3
"""Paired offline native benchmarks of the full Stats history and event list."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compile_benchmark(project, root, folder, version):
    models = root / "Sources/ContainerDeskCore/Models"
    inputs = [models / (name + ".swift") for name in ["ResourceSummary", "ContainerCPUUsage", "ContainerMetricsHistory", "ContainerMetricSeries"]]
    chart = root / "Sources/ContainerDeskApp/Features/ContainerMetricChart.swift"
    history = root / "Sources/ContainerDeskApp/Features/ContainerMetricsHistoryView.swift"
    generated_chart = folder / (version + "-chart.swift")
    generated_chart.write_text(chart.read_text().replace("import ContainerDeskCore\n", ""))
    source = history.read_text().replace("import ContainerDeskCore\n", "")
    substitutions = {
        "@State private var minutes = 15": "@State private var minutes = StatsBenchmarkClock.minutes",
        "@State private var hoveredDate: Date?": "@Binding var hoveredDate: Date?",
        "TimelineView(.periodic(from: .now, by: 5)) { context in": "TimelineView(.explicit([StatsBenchmarkClock.end])) { _ in",
        "                    ForEach(events.reversed()) { event in": "                    ForEach(events.reversed()) { event in\n                        let _ = StatsBenchmarkClock.eventRow()",
    }
    for old, new in substitutions.items():
        if source.count(old) != 1:
            raise ValueError("Cannot adapt current native history source: " + old)
        source = source.replace(old, new)
    source = source.replace("context.date", "StatsBenchmarkClock.end")
    generated_history = folder / (version + "-history.swift")
    generated_history.write_text(source)
    binary = folder / version
    cache = project / ".build/stats-benchmark-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache),
                    *map(str, inputs), str(generated_chart), str(generated_history),
                    str(project / "script/benchmarks/StatsPerformanceBench.swift"), "-o", str(binary)], check=True)
    return binary, {str(path.relative_to(root)): sha256(path) for path in [*inputs, chart, history]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paired-baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--assert-improvement", action="store_true")
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("rounds must be positive")
    project = Path(__file__).resolve().parents[1]
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    runs = []
    hashes = {}
    with tempfile.TemporaryDirectory(prefix="containerdesk-stats-benchmark-") as temp:
        binaries = {}
        for version, root in [("before", args.paired_baseline.resolve()), ("after", project)]:
            binaries[version], hashes[version] = compile_benchmark(project, root, Path(temp), version)
        for round_index in range(args.rounds):
            for samples in [900, 3600]:
                for events in [0, 1000, 5000]:
                    for version in (["before", "after"] if round_index % 2 == 0 else ["after", "before"]):
                        command = [str(binaries[version]), str(samples), str(events)]
                        if round_index == 0 and samples == 900 and events == 1000:
                            command.append(str(args.output.parent / ("stats-" + version + ".png")))
                        completed = subprocess.run(command, capture_output=True, text=True, timeout=90, check=True)
                        row = json.loads(completed.stdout)
                        if not row["processed"] or row["events"] != events:
                            raise RuntimeError("Stats fixture did not process the expected data and selections")
                        runs.append(dict(row, version=version, round=round_index))
    summary = []
    for samples in [900, 3600]:
        for events in [0, 1000, 5000]:
            row = dict(samples=samples, events=events)
            for version in ["before", "after"]:
                selected = [r for r in runs if r["version"] == version and r["samples"] == samples and r["events"] == events]
                row[version + "_initial_median_ms"] = statistics.median(r["initial_ms"] for r in selected)
                row[version + "_hover_median_ms"] = statistics.median(t for r in selected for t in r["hover_ms"])
                row[version + "_initial_rows_max"] = max(r["initial_event_row_evaluations"] for r in selected)
                row[version + "_hover_rows_max"] = max(t for r in selected for t in r["hover_event_row_evaluations"])
            summary.append(row)
    harness = [Path(__file__).resolve(), project / "script/benchmarks/StatsPerformanceBench.swift"]
    result = dict(scope="Full native HistoryView in a hidden 1200x700 ScrollView. Injected frozen clock/selection and history-only observable monitor; real chart/history source. Selection-to-layout settlement with 1ms runloop pump, not displayed FPS/GPU/RSS or whole-app profiling.",
                  rounds=args.rounds, machine=platform.platform(), swift=subprocess.check_output(["swiftc", "--version"], text=True).strip(),
                  source_sha256=hashes, harness_sha256={str(p.relative_to(project)): sha256(p) for p in harness}, summary=summary, runs=runs)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    for row in summary:
        print(f"{row['samples']} samples / {row['events']} events: initial {row['before_initial_median_ms']:.2f} → {row['after_initial_median_ms']:.2f} ms; hover {row['before_hover_median_ms']:.2f} → {row['after_hover_median_ms']:.2f} ms; initial event rows {row['before_initial_rows_max']} → {row['after_initial_rows_max']}")
    if args.assert_improvement:
        for row in summary:
            if row["events"] >= 1000 and (row["after_initial_rows_max"] >= row["events"] // 2 or
                    row["after_initial_median_ms"] >= row["before_initial_median_ms"] or
                    row["after_hover_median_ms"] >= row["before_hover_median_ms"]):
                raise SystemExit("Stats regression: offscreen event rows were evaluated eagerly or event-heavy layout/hover did not improve")


if __name__ == "__main__":
    main()

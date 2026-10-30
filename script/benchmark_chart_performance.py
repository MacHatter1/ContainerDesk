#!/usr/bin/env python3
"""Compare actual native Swift Charts hover/layout work using a preserved source baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile


def instrument_chart(source):
    source = source.replace("import ContainerDeskCore\n", "")
    # Fail closed if the source shape changes: never benchmark a stale fixture.
    projection = "        let series = projection.value("
    if source.count(projection) != 1:
        raise ValueError("Expected exactly one real series projection")
    line_end = source.index("\n", source.index(projection))
    source = source[:line_end] + "\n        let _ = ChartBenchmarkRecorder.projection(projection.buildCount)" + source[line_end:]
    if "struct ContainerMetricPlot:" in source:
        marker = "    var body: some View {\n        Chart {"
        replacement = "    var body: some View {\n        let _ = ChartBenchmarkRecorder.plot()\n        Chart {"
    else:
        marker = "    var body: some View {\n        let series ="
        replacement = "    var body: some View {\n        let _ = ChartBenchmarkRecorder.plot()\n        let series ="
    if source.count(marker) != 1:
        raise ValueError("Cannot locate actual static plot body")
    return source.replace(marker, replacement)


def compile_benchmark(project, root, folder, name):
    chart = root / "Sources/ContainerDeskApp/Features/ContainerMetricChart.swift"
    generated = folder / (name + ".swift")
    generated.write_text(instrument_chart(chart.read_text()))
    models = root / "Sources/ContainerDeskCore/Models"
    names = ["ResourceSummary", "ContainerCPUUsage", "ContainerMetricsHistory", "ContainerMetricSeries"]
    paths = [models / (name + ".swift") for name in names]
    cache = project / ".build/chart-benchmark-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    binary = folder / name
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache),
                    *map(str, paths), str(generated), str(project / "script/benchmarks/ChartPerformanceBench.swift"), "-o", str(binary)], check=True)
    return binary, {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [chart, *paths]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paired-baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--assert-improvement", action="store_true", help="Require cheaper hover work and no static plot rebuilding")
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("rounds must be positive")
    project = Path(__file__).resolve().parents[1]
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    runs = []
    fingerprints = {}
    with tempfile.TemporaryDirectory(prefix="containerdesk-chart-benchmark-") as temp:
        binaries = {}
        for name, root in [("before", args.paired_baseline.resolve()), ("after", project)]:
            binaries[name], fingerprints[name] = compile_benchmark(project, root, Path(temp), name)
        for round_index in range(args.rounds):
            for samples in [900, 3600]:
                for events in [0, 100, 1000, 5000]:
                    for version in (["before", "after"] if round_index % 2 == 0 else ["after", "before"]):
                        command = [str(binaries[version]), str(samples), str(events)]
                        if round_index == 0 and samples == 900 and events == 0:
                            command.append(str(args.output.parent / ("chart-" + version + ".png")))
                        run = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
                        row = json.loads(run.stdout)
                        if not row["processed_updates"]:
                            raise RuntimeError("Native chart did not process selection updates")
                        runs.append(dict(row, version=version, round=round_index))
    summary = []
    for samples in [900, 3600]:
        for events in [0, 100, 1000, 5000]:
            row = dict(samples_each=samples, events=events)
            for version in ["before", "after"]:
                selected = [r for r in runs if r["version"] == version and r["samples_each"] == samples and r["events"] == events]
                row[version + "_median_ms"] = statistics.median(t for r in selected for t in r["hover_update_ms"])
                row[version + "_plot_bodies_max"] = max(t for r in selected for t in r["static_plot_body_calls"])
            row["speedup"] = row["before_median_ms"] / row["after_median_ms"]
            summary.append(row)
    report = dict(scope="Two real native charts in a hidden 1200x360 NSHostingView. Selection-to-layout settlement with 1ms runloop pump; no displayed frame-rate, GPU, RSS or whole-app claim.",
                  machine=platform.platform(), swift=subprocess.check_output(["swiftc", "--version"], text=True).strip(), rounds=args.rounds,
                  source_sha256=fingerprints,
                  harness_sha256={str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [Path(__file__).resolve(), project / "script/benchmarks/ChartPerformanceBench.swift"]},
                  summary=summary, runs=runs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    for row in summary:
        print(f"{row['samples_each']:4} samples / {row['events']:4} events: {row['before_median_ms']:.2f} → {row['after_median_ms']:.2f} ms ({row['speedup']:.1f}x); static plot bodies {row['before_plot_bodies_max']} → {row['after_plot_bodies_max']}")
    if args.assert_improvement and any(r["after_plot_bodies_max"] != 0 or r["speedup"] <= 1 for r in summary):
        raise SystemExit("Chart hover regression: static plots rebuilt or hover did not improve")


if __name__ == "__main__":
    main()

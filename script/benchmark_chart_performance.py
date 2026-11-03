#!/usr/bin/env python3
"""Compare native chart hover/layout work using a preserved source baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile

CORE_MODEL_NAMES = ["ResourceSummary", "ContainerCPUUsage", "ContainerMetricsHistory", "ContainerMetricSeries"]
CORE_MODELS = Path("Sources/ContainerDeskCore/Models")


def chart_sources(root):
    """The chart view plus whichever split-out helpers this source tree has."""
    chart = root / "Sources/ContainerDeskApp/Features/ContainerMetricChart.swift"
    helpers = [chart.with_name(name + ".swift") for name in ["ContainerMetricPlot", "ContainerMetricPlotGeometry"]]
    return [chart, *[path for path in helpers if path.exists()]]


def core_models(root):
    return [root / CORE_MODELS / (name + ".swift") for name in CORE_MODEL_NAMES]


def instrument_chart(source):
    source = source.replace("import ContainerDeskCore\n", "")
    # Fail closed if the source shape changes: never benchmark a stale fixture.
    projection = "        let series = projection.value("
    if source.count(projection) != 1:
        raise ValueError("Expected exactly one real series projection")
    line_end = source.index("\n", source.index(projection))
    source = source[:line_end] + "\n        let _ = ChartBenchmarkRecorder.projection(projection.buildCount)" + source[line_end:]
    if "        let paths = cache.value(" in source:
        marker = "    var body: some View {\n        let paths = cache.value("
        replacement = "    var body: some View {\n        let _ = ChartBenchmarkRecorder.plot()\n        let paths = cache.value("
    elif "struct ContainerMetricPlot:" in source:
        marker = "    var body: some View {\n        Chart {"
        replacement = "    var body: some View {\n        let _ = ChartBenchmarkRecorder.plot()\n        Chart {"
    else:
        marker = "    var body: some View {\n        let series ="
        replacement = "    var body: some View {\n        let _ = ChartBenchmarkRecorder.plot()\n        let series ="
    if source.count(marker) != 1:
        raise ValueError("Cannot locate actual static plot body")
    source = source.replace(marker, replacement)
    readout = "private struct ContainerMetricReadoutValue:" if "private struct ContainerMetricReadoutValue:" in source else "private struct ContainerMetricReadout:"
    if source.count(readout) != 1:
        raise ValueError("Cannot locate the displayed readout content")
    readout_body = source.index("        HStack(alignment: .top)", source.index(readout))
    source = source[:readout_body] + "        let _ = ChartBenchmarkRecorder.readout()\n" + source[readout_body:]
    if "        let paths = cache.value(" in source:
        canvas = "        Canvas { context, size in\n"
        if source.count(canvas) != 1:
            raise ValueError("Cannot locate the static chart drawing")
        source = source.replace(canvas, canvas + "            ChartBenchmarkRecorder.plotDraw()\n")
    return source


def compile_benchmark(project, root, folder, name):
    sources = chart_sources(root)
    generated = folder / (name + ".swift")
    generated.write_text(instrument_chart("\n".join(path.read_text() for path in sources)))
    paths = core_models(root)
    cache = (project / ".build/chart-benchmark-module-cache").resolve()
    cache.mkdir(parents=True, exist_ok=True)
    binary = folder / name
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache),
                    *map(str, paths), str(generated), str(project / "script/benchmarks/ChartPerformanceBench.swift"), "-o", str(binary)], check=True)
    return binary, {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [*sources, *paths]}


def compile_pair(project, baseline, folder):
    hashes = {}
    models = core_models(project)
    for current, before in zip(models, core_models(baseline)):
        if before.read_bytes() != current.read_bytes():
            raise ValueError("Paired chart comparison requires identical Core models; use --separate-processes for Core changes")
    generated = []
    for version, root in [("before", baseline), ("after", project)]:
        paths = chart_sources(root)
        source = instrument_chart("\n".join(path.read_text() for path in paths))
        if version == "before":
            # Namespace only types declared by the chart source; shared Core
            # types are byte-verified above. No rendering logic is substituted.
            declared = set(re.findall(r"(?m)^\s*(?:(?:private|fileprivate|internal|public|final|@MainActor)\s+)*(?:struct|class|enum)\s+(ContainerMetric\w+)", source))
            for name in sorted(declared, key=len, reverse=True):
                source = re.sub(r"\b" + name + r"\b", "Before" + name, source)
            source = source.replace("ChartBenchmarkRecorder", "BeforeChartBenchmarkRecorder")
            source = source.replace(".chartColor", ".beforeChartColor").replace("var chartColor:", "var beforeChartColor:")
        path = folder / (version + ".swift")
        path.write_text(source)
        generated.append(path)
        hashes[version] = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [*paths, *core_models(root)]}
    binary = folder / "paired"
    cache = (project / ".build/chart-benchmark-module-cache").resolve()
    cache.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache),
                    *map(str, models), *map(str, generated), str(project / "script/benchmarks/PairedChartPerformanceBench.swift"), "-o", str(binary)], check=True)
    return binary, hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paired-baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--hover-updates", type=int, default=100, help="Timed hover changes per fresh process, after two warmup changes")
    parser.add_argument("--separate-processes", action="store_true", help="Diagnostic legacy mode; default pairs alternating baseline/current hovers in one process")
    parser.add_argument("--assert-improvement", action="store_true", help="Require cheaper hover work and no static plot rebuilding")
    args = parser.parse_args()
    if args.rounds < 1 or args.hover_updates < 1:
        parser.error("rounds and hover update count must be positive")
    project = Path(__file__).resolve().parents[1]
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    runs = []
    fingerprints = {}
    with tempfile.TemporaryDirectory(prefix="containerdesk-chart-benchmark-") as temp:
        binaries = {}
        if args.separate_processes:
            for name, root in [("before", args.paired_baseline.resolve()), ("after", project)]:
                binaries[name], fingerprints[name] = compile_benchmark(project, root, Path(temp), name)
        else:
            paired, fingerprints = compile_pair(project, args.paired_baseline.resolve(), Path(temp))
        for round_index in range(args.rounds):
            for samples in [900, 3600]:
                for events in [0, 100, 1000, 5000]:
                    if not args.separate_processes:
                        completed = subprocess.run([str(paired), str(samples), str(events), str(args.hover_updates), str(round_index)], capture_output=True, text=True, timeout=120, check=True)
                        for row in json.loads(completed.stdout):
                            if not row["processed_updates"] or len(row["hover_update_ms"]) != args.hover_updates:
                                raise RuntimeError("Paired native charts did not process selection updates")
                            runs.append(dict(row, round=round_index))
                        continue
                    for version in (["before", "after"] if round_index % 2 == 0 else ["after", "before"]):
                        command = [str(binaries[version]), str(samples), str(events), str(args.hover_updates)]
                        if round_index == 0 and samples == 900 and events == 0:
                            command.append(str(args.output.parent / ("chart-" + version + ".png")))
                        run = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
                        row = json.loads(run.stdout)
                        if not row["processed_updates"] or len(row["hover_update_ms"]) != args.hover_updates:
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
                row[version + "_readout_bodies_max"] = max(t for r in selected for t in r["readout_body_calls"])
                row[version + "_plot_draws_max"] = max(t for r in selected for t in r["static_plot_draw_calls"])
                row[version + "_plot_draw_counter"] = all(r["plot_draw_instrumented"] for r in selected)
                if not args.separate_processes:
                    row[version + "_cpu_median_ms"] = statistics.median(t for r in selected for t in r["hover_thread_cpu_ms"])
            row["speedup"] = row["before_median_ms"] / row["after_median_ms"]
            summary.append(row)
    harness = "ChartPerformanceBench.swift" if args.separate_processes else "PairedChartPerformanceBench.swift"
    report = dict(scope="Two real native charts per version in hidden 1200x360 NSHostingViews. Default mode alternates baseline/current hovers within one process. Selection-to-layout settlement with 1ms runloop pump; no displayed frame-rate, GPU, RSS or whole-app claim.",
                  machine=platform.platform(), swift=subprocess.check_output(["swiftc", "--version"], text=True).strip(), rounds=args.rounds, hover_updates=args.hover_updates,
                  source_sha256=fingerprints,
                  separate_processes=args.separate_processes,
                  harness_sha256={str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [Path(__file__).resolve(), project / "script/benchmarks" / harness]},
                  summary=summary, runs=runs)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    for row in summary:
        print(f"{row['samples_each']:4} samples / {row['events']:4} events: {row['before_median_ms']:.2f} → {row['after_median_ms']:.2f} ms ({row['speedup']:.1f}x); static plot bodies {row['before_plot_bodies_max']} → {row['after_plot_bodies_max']}")
    if args.assert_improvement and any(
        r["after_plot_bodies_max"] != 0 or not r["after_plot_draw_counter"] or r["after_plot_draws_max"] != 0
        or r["after_readout_bodies_max"] > 1 or r["speedup"] <= 1 for r in summary
    ):
        raise SystemExit("Chart hover regression: static plot work, redundant readout layout, or hover did not improve")


if __name__ == "__main__":
    main()

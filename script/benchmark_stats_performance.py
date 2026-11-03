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


def compile_benchmark(project, root, folder, version, *, harness=None, manual_refresh=False):
    models = root / "Sources/ContainerDeskCore/Models"
    inputs = [models / (name + ".swift") for name in ["ResourceSummary", "ContainerCPUUsage", "ContainerMetricsHistory", "ContainerMetricSeries"]]
    chart = root / "Sources/ContainerDeskApp/Features/ContainerMetricChart.swift"
    helpers = [chart.with_name(name + ".swift") for name in ["ContainerMetricPlot", "ContainerMetricPlotGeometry"] if chart.with_name(name + ".swift").exists()]
    history = root / "Sources/ContainerDeskApp/Features/ContainerMetricsHistoryView.swift"
    generated_chart = folder / (version + "-chart.swift")
    chart_source = "\n".join(path.read_text() for path in [chart, *helpers]).replace("import ContainerDeskCore\n", "")
    marker = "        let series = projection.value("
    if chart_source.count(marker) != 1:
        raise ValueError("Cannot locate the real chart projection")
    end = chart_source.index("\n", chart_source.index(marker))
    window = (", window: Int(end.timeIntervalSince(start) / 60)" if manual_refresh else "") + ", metric: metric.title"
    if helpers:
        canvas = "        Canvas { context, size in"
        draw_end = "        }\n        .accessibilityElement(children: .ignore)"
        if chart_source.count(canvas) != 1 or chart_source[chart_source.index(canvas):].count(draw_end) != 1:
            raise ValueError("Cannot locate the completed chart drawing")
        draw_position = chart_source.index(draw_end, chart_source.index(canvas))
        chart_source = chart_source[:draw_position] + "            StatsBenchmarkClock.rendered(points.last?.date, count: sampleCount" + window + ")\n" + chart_source[draw_position:]
    else:
        chart_source = chart_source[:end] + "\n        let _ = StatsBenchmarkClock.rendered(samples.last?.date, count: samples.count" + window + ")" + chart_source[end:]
    generated_chart.write_text(chart_source)
    source = history.read_text().replace("import ContainerDeskCore\n", "")
    substitutions = {
        "@State private var minutes = 15": "@State private var minutes = StatsBenchmarkClock.minutes",
        "@State private var hoveredDate: Date?": "@Binding var hoveredDate: Date?",
    }
    for old, new in substitutions.items():
        if source.count(old) != 1:
            raise ValueError("Cannot adapt current native history source: " + old)
        source = source.replace(old, new)
    source = source.replace("context.date", "StatsBenchmarkClock.end")
    timeline = "TimelineView(.periodic(from: .now, by: 5)) { context in"
    publications = [
        "snapshot = ContainerHistorySnapshot(history: monitoring.history, containerID: containerID, minutes: minutes, at: .now)",
        "snapshot = ContainerHistorySnapshot(history: monitoring.history, containerID: containerID, at: .now)",
    ]
    publication = next((value for value in publications if source.count(value) == 1), None)
    if source.count(timeline) == 1:
        source = source.replace(timeline, "TimelineView(.explicit([StatsBenchmarkClock.end])) { _ in")
        if manual_refresh:
            source = source.replace("    let monitoring: ContainerMonitoringStore", "    let monitoring: ContainerMonitoringStore\n    var isActive = true")
            source = source.replace("            let end =", "            let _ = StatsBenchmarkClock.publication()\n            let end =", 1)
    elif publication is not None:
        source = source.replace(publication, publication.replace("at: .now", "at: StatsBenchmarkClock.end"))
        source = source.replace("Date.now", "StatsBenchmarkClock.end")
        if manual_refresh:
            source = source.replace("                snapshot = ContainerHistorySnapshot", "                StatsBenchmarkClock.publication()\n                snapshot = ContainerHistorySnapshot")
            sleep = "try await Task.sleep(for: refreshInterval)"
            if source.count(sleep) != 1:
                raise ValueError("Cannot adapt the presentation refresh clock")
            source = source.replace(sleep, "try await StatsBenchmarkClock.sleep()")
    else:
        raise ValueError("Cannot locate the production Stats publication path")
    if manual_refresh:
        # Keep the disposable memberwise initializer consistent for both versions.
        source = source.replace("    var isActive = true\n", "")
        source = source.replace("    let monitoring: ContainerMonitoringStore", "    let monitoring: ContainerMonitoringStore\n    var isActive = true")
        label = 'Label("History & Events", systemImage: "chart.xyaxis.line").font(.headline)'
        if source.count(label) != 1:
            raise ValueError("Cannot locate the production picker header")
        source = source.replace(label, "let _ = StatsBenchmarkClock.pickerBody()\n            " + label)
    event = "ForEach(events.reversed()) { event in"
    if source.count(event) != 1:
        raise ValueError("Cannot locate event rows")
    source = source.replace(event, event + "\n                        let _ = StatsBenchmarkClock.eventRow()")
    generated_history = folder / (version + "-history.swift")
    generated_history.write_text(source)
    binary = folder / version
    cache = project / ".build/stats-benchmark-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache),
                    *map(str, inputs), str(generated_chart), str(generated_history),
                    str(harness or project / "script/benchmarks/StatsPerformanceBench.swift"), "-o", str(binary)], check=True)
    return binary, {str(path.relative_to(root)): sha256(path) for path in [*inputs, chart, *helpers, history]}


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

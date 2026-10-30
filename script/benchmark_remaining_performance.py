#!/usr/bin/env python3
"""Paired offline release benchmarks for log responsiveness, charts and history."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from benchmark_performance import aggregate, compare


def compile_benchmark(project, source_root, binary, cache, optimized):
    models = source_root.resolve() / "Sources/ContainerDeskCore/Models"
    names = ["ResourceSummary", "ContainerCPUUsage", "ContainerMetricsHistory", "ContainerLogBuffer", "ContainerLogProjection"]
    flags = []
    if optimized:
        names.append("ContainerMetricSeries")
        flags = ["-D", "OPTIMIZED_REMAINING"]
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache), *flags,
                    *[str(models / (name + ".swift")) for name in names],
                    str(project / "script/benchmarks/RemainingPerformanceBench.swift"), "-o", str(binary)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paired-baseline", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("rounds must be positive")
    project = Path(__file__).resolve().parents[1]
    cache = project / ".build/performance-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="containerdesk-remaining-bench-") as temp:
        binaries = {name: Path(temp) / name for name in ["before", "after"]}
        compile_benchmark(project, args.paired_baseline, binaries["before"], cache, False)
        compile_benchmark(project, project, binaries["after"], cache, True)
        runs = {"before": [], "after": []}
        order = []
        for index in range(args.rounds):
            for name in (["before", "after"] if index % 2 == 0 else ["after", "before"]):
                runs[name].append(json.loads(subprocess.check_output([str(binaries[name])], text=True)))
                order.append(name)
        before, after = aggregate(runs["before"]), aggregate(runs["after"])
        result = {"before": before, "after": after, "execution_order": order, "comparison": compare(before, after),
                  "baseline_source_root": str(args.paired_baseline.resolve()), "source_root": str(project),
                  "compiler": subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT).strip()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()

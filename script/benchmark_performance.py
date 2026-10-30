#!/usr/bin/env python3
"""Offline release benchmarks. Use --baseline with a preserved source tree for comparison."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile


def compile_benchmark(project, source_root, baseline, binary, cache):
    models = source_root.resolve() / "Sources/ContainerDeskCore/Models"
    sources = [models / f"{name}.swift" for name in ("ResourceSummary", "ManagedStack", "StackWorkspace", "ContainerLogBuffer")]
    flags = []
    if not baseline:
        sources += [models / "StackWorkspaceCache.swift", models / "ContainerLogProjection.swift"]
        flags = ["-D", "OPTIMIZED_PIPELINE"]
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(cache), *flags, *map(str, sources), str(project / "script/benchmarks/PerformanceBench.swift"), "-o", str(binary)], check=True)


def aggregate(runs):
    result = runs[0]
    for run in runs[1:]:
        if run["checksum"] != result["checksum"]:
            raise SystemExit("Output checksum changed between repetitions.")
        by_name = {row["name"]: row for row in run["results"]}
        for row in result["results"]:
            row["milliseconds"].extend(by_name[row["name"]]["milliseconds"])
    result["rounds"] = len(runs)
    for row in result["results"]:
        row["median_ms"] = statistics.median(row["milliseconds"])
        row["min_ms"] = min(row["milliseconds"])
        row["max_ms"] = max(row["milliseconds"])
    return result


def compare(before, after):
    if before["checksum"] != after["checksum"]:
        raise SystemExit("Benchmark output checksum changed; investigate correctness before comparing speed.")
    previous = {row["name"]: row for row in before["results"]}
    comparison = []
    for row in after["results"]:
        old = previous[row["name"]]["median_ms"]
        item = {"name": row["name"], "before_ms": old, "after_ms": row["median_ms"], "speedup": old / row["median_ms"]}
        comparison.append(item)
        print(f"{item['name']}: {old:.4f} -> {item['after_ms']:.4f} ms ({item['speedup']:.2f}x)")
    return comparison


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--compare", type=Path)
    parser.add_argument("--paired-baseline", type=Path, help="Compile both trees and alternate their execution order")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1 or (args.paired_baseline and (args.baseline or args.compare)):
        parser.error("Use positive rounds; paired mode cannot also use --baseline or --compare.")
    project = Path(__file__).resolve().parents[1]
    cache = project / ".build/performance-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="containerdesk-benchmark-") as temporary:
        binary = Path(temporary) / "benchmark"
        compile_benchmark(project, args.source_root, args.baseline, binary, cache)
        if args.paired_baseline:
            baseline_binary = Path(temporary) / "before"
            compile_benchmark(project, args.paired_baseline, True, baseline_binary, cache)
            runs = {"before": [], "after": []}
            order = []
            for round_number in range(args.rounds):
                names = ["before", "after"] if round_number % 2 == 0 else ["after", "before"]
                for name in names:
                    executable = baseline_binary if name == "before" else binary
                    runs[name].append(json.loads(subprocess.check_output([str(executable)], text=True)))
                    order.append(name)
            before, after = aggregate(runs["before"]), aggregate(runs["after"])
            result = {"before": before, "after": after, "execution_order": order, "comparison": compare(before, after), "baseline_source_root": str(args.paired_baseline.resolve())}
        else:
            result = aggregate([json.loads(subprocess.check_output([str(binary)], text=True)) for _ in range(args.rounds)])
            if args.compare:
                result["comparison"] = compare(json.loads(args.compare.read_text()), result)
    result["compiler"] = subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT).strip()
    result["source_root"] = str(args.source_root.resolve())
    result["baseline"] = args.baseline
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()

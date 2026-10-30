# Performance verification

The benchmark runners use synthetic, offline fixtures. They compile release code with the local Swift toolchain, warm it up and alternate baseline/current execution order over three rounds. The two Core runners compare medians from 21 timed observations per version; the native chart and Stats runners use 15 selection updates per workload. Stats also records three fresh-process initial layouts. Source trees must be preserved before editing; a Git baseline alone omits uncommitted files. These runners do not contact a container runtime, download models or change app preferences.

`script/benchmark_performance.py` covers stack catalog rebuilding, metric-driven workspace reads, log eviction and repeated log projections. Its original baseline predates the stack/log cache and queue changes.

`script/benchmark_remaining_performance.py` covers the subsequent changes:

- Chart derivation at 3,600 samples and 100/1,000/5,000 limit-change events, including five repeated hover-style reads. The baseline transform reproduces the original chart's segmentation and statistics; the current transform uses the production Core series/projection. Five thousand events in one chart is a stress upper bound, not a typical session.
- Metrics append/prune at an hour of one-second samples for 1/10/100 containers. Both versions use their production history implementation; a sample snapshot check runs outside the timed append.
- A fresh 20,000-line text filter, reporting both completion time and the delay before a queued main-actor heartbeat runs. Moving a filter off the main actor improves responsiveness even when total matching time is unchanged.

Every process emits a deterministic result checksum; the runner refuses comparisons with mismatched checksums. This is a coarse semantic guard rather than a hash of every field. Maintained Swift tests separately compare mixed-event chart segmentation with the original transform, verify extrema/segment-preserving downsampling, exercise queue snapshot/copy/retention behavior, and check asynchronous log filters for cancellation, supersession, Unicode, source/range filters and session changes.

The UI uses cancellable filtering of immutable log publications. It keeps the last coherent publication visible while newer lines are processed, so the console does not flash empty on every batch. A query, source, range or session change hides incompatible results immediately. Export uses the same rows currently displayed. Late workers cannot replace a newer result.

Charts reuse derived points/statistics while the cursor moves. The static series, event rules and axes have an equality boundary covering all their inputs. The shared cursor and readouts update in separate views; selection markers use the chart proxy's plot coordinates without recreating the Swift Charts marks. Event segmentation uses sorted break dates and a forward cursor, rather than scanning all events for every sample. Plotted points are reduced according to view width while preserving bucket extrema and both sides of segment boundaries. Hover and summary statistics still use the complete retained history. Discontinuity preservation may exceed the nominal plotting budget when history contains many segments.

History uses value-semantic bounded queues with amortised compaction. Interactive callers use `samples(for:)` or `latestSample(for:)`; the compatibility `samples` property materialises an export snapshot of all containers and should not be used per metric tick. Queue backing storage can retain bounded spare capacity between compactions; an append microbenchmark does not establish app RSS improvements.

The two Core runners exclude API/CLI collection, SwiftUI layout/Charts rendering, scrolling, energy, startup and peak RSS. Cached-read ratios describe reuse of derived results, not faster execution of a genuine fresh search or transform.

`script/benchmark_chart_performance.py` measures the real `ContainerMetricChart` in two hidden native `NSHostingView` cards at 1,200 × 360 points. Each workload runs in a fresh process with 900 or 3,600 samples per chart and 0/100/1,000/5,000 events. Five idle layout pumps and two selection updates warm up each process before five timed updates. A selection-change checkpoint and layout/transaction flush use the same completion criterion for both versions. Counters inserted into disposable source copies verify whether hover reevaluates static plot bodies; the shipping app has no benchmark instrumentation. Maintained native accessibility tests separately verify CPU/RAM selections, gaps, clearing, normalization and sample/event updates.

Run it against a complete source snapshot preserved before editing:

```sh
python3 script/benchmark_chart_performance.py \
  --paired-baseline /absolute/path/to/before \
  --output output/chart-performance/paired.json \
  --rounds 3 --assert-improvement
```

The JSON records source/harness hashes, toolchain, raw observations, medians and static plot evaluations. The improvement gate requires faster median hover settlement and zero static plot evaluations during cursor changes for every workload. Initial series/event rendering is still proportional to the plotted data. Native measurements include hidden component layout and selection settlement with a 1 ms run-loop pump; they do not establish displayed frame rates, GPU cost, full-app scrolling, energy or RSS. Use a full-app Instruments capture for those claims.

The full Stats history uses a lazy vertical layout so offscreen event rows do not participate in initial layout and hover updates. The complete event data remains available when scrolling and switching the 15/60-minute range. Native regression tests exercise both widths, range changes, oldest/newest event access and live additions; chart tests separately cover shared selection, gaps, units and CPU normalization.

`script/benchmark_stats_performance.py` measures the production history view, chart cards and event list together inside a hidden 1,200 × 700 point ScrollView. It injects a frozen clock, controllable hover binding and history-only observable monitor into disposable source copies. Both versions receive the same adapters; no benchmark counters ship in the app. Workloads use 900/3,600 samples and 0/1,000/5,000 events, with five layout pumps and two selection changes before five timed changes per fresh process. Five thousand events is a stress case. Initial chart/event-rule rendering remains proportional to the plotted data even when event rows are lazy.

```sh
python3 script/benchmark_stats_performance.py \
  --paired-baseline /absolute/path/to/before \
  --output output/stats-performance/paired.json \
  --rounds 3 --assert-improvement
```

The Stats gate requires initial event-row evaluations below half the fixture’s event count, plus lower median initial-layout and hover costs for event-heavy workloads. JSON includes all raw timings, row evaluations, source/harness hashes and toolchain. These are native component settlement measurements with a 1 ms run-loop pump, with the same scope limits as the chart benchmark above.

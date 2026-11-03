# Performance verification

The component benchmark runners use synthetic, offline fixtures. They compile release code with the local Swift toolchain, warm it up and alternate baseline/current execution order over three rounds. The two Core runners compare medians from 21 timed observations per version; the native chart runner uses 300 selection updates per workload by default, and the Stats runner uses 15. Stats also records three fresh-process initial layouts. Source trees must be preserved before editing; a Git baseline alone omits uncommitted files. These runners do not contact a container runtime, download models or change app preferences.

`script/benchmark_performance.py` covers stack catalog rebuilding, metric-driven workspace reads, log eviction and repeated log projections. Its original baseline predates the stack/log cache and queue changes.

`script/benchmark_remaining_performance.py` covers the subsequent changes:

- Chart derivation at 3,600 samples and 100/1,000/5,000 limit-change events, including five repeated hover-style reads. The baseline transform reproduces the original chart's segmentation and statistics; the current transform uses the production Core series/projection. Five thousand events in one chart is a stress upper bound, not a typical session.
- Metrics append/prune at an hour of one-second samples for 1/10/100 containers. Both versions use their production history implementation; a sample snapshot check runs outside the timed append.
- A fresh 20,000-line text filter, reporting both completion time and the delay before a queued main-actor heartbeat runs. Moving a filter off the main actor improves responsiveness even when total matching time is unchanged.

Every process emits a deterministic result checksum; the runner refuses comparisons with mismatched checksums. This is a coarse semantic guard rather than a hash of every field. Maintained Swift tests separately compare mixed-event chart segmentation with the original transform, verify extrema/segment-preserving downsampling, exercise queue snapshot/copy/retention behavior, and check asynchronous log filters for cancellation, supersession, Unicode, source/range filters and session changes.

The UI uses cancellable filtering of immutable log publications. It keeps the last coherent publication visible while newer lines are processed, so the console does not flash empty on every batch. A query, source, range or session change hides incompatible results immediately. Export uses the same rows currently displayed. Late workers cannot replace a newer result.

Charts reuse derived points/statistics while the cursor moves. The static series, event rules and axes have an equality boundary covering all their inputs. The shared cursor and readouts update in separate views. Drawing and inspection share the same explicit plot frame and linear coordinate transform. Event segmentation uses sorted break dates and a forward cursor, rather than scanning all events for every sample. Plotted points are reduced according to view width while preserving bucket extrema and both sides of segment boundaries. Hover and summary statistics still use the complete retained history. Discontinuity preservation may exceed the nominal plotting budget when history contains many segments.

History uses value-semantic bounded queues with amortised compaction. Interactive callers use `samples(for:)` or `latestSample(for:)`; the compatibility `samples` property materialises an export snapshot of all containers and should not be used per metric tick. Queue backing storage can retain bounded spare capacity between compactions; an append microbenchmark does not establish app RSS improvements.

The two Core runners exclude API/CLI collection, SwiftUI layout/Charts rendering, scrolling, energy, startup and peak RSS. Cached-read ratios describe reuse of derived results, not faster execution of a genuine fresh search or transform.

`script/benchmark_chart_performance.py` measures the real `ContainerMetricChart` in two hidden native `NSHostingView` cards at 1,200 × 360 points. Each workload runs in a fresh process with 900 or 3,600 samples per chart and 0/100/1,000/5,000 events. Five idle layout pumps and two selection updates warm up each version before 100 timed updates per process. The default harness puts baseline and current charts in separate hidden windows within one process, alternating which version runs first on each hover. Core model sources must be byte-identical; the baseline chart types are namespaced without changing their rendering logic. This pairs scheduling, timer and power-management conditions. A temporary user-initiated activity prevents App Nap. A selection-change checkpoint and layout/transaction flush use the same completion criterion for both versions. Counters inserted into disposable source copies track static plot bodies/drawings and displayed readout construction; the shipping app has no benchmark instrumentation. Maintained native accessibility tests separately verify CPU/RAM selections, gaps, clearing, normalization and sample/event updates.

Run it against a complete source snapshot preserved before editing:

```sh
python3 script/benchmark_chart_performance.py \
  --paired-baseline /absolute/path/to/before \
  --output output/chart-performance/paired.json \
  --rounds 3 --assert-improvement
```

The JSON records source/harness hashes, toolchain, raw wall/CPU observations, medians and view/drawing counters. The improvement gate requires faster median hover settlement, zero static plot evaluations/drawings, and at most one readout construction during each cursor change in every workload. The fixture's RAM values all round to the same displayed number, so its memory readout must stay unchanged while CPU updates. Use `--rounds 5` for 500 observations per workload; `--hover-updates` controls the observation count and `--separate-processes` retains the earlier diagnostic mode. Timing and improvement thresholds are unchanged. Initial series/event rendering is still proportional to the plotted data. Native measurements include hidden component layout and selection settlement with a 1 ms run-loop pump; they do not establish displayed frame rates, GPU cost, full-app scrolling, energy or RSS. Use a full-app Instruments capture for those claims.

The full Stats history uses a lazy vertical layout so offscreen event rows do not participate in initial layout and hover updates. The range-filtered hour is built once per publication or range change; cursor updates re-evaluate the view with the same arrays, so the chart caches recognise unchanged inputs without comparing every element. The complete event data remains available when scrolling and switching the 15/60-minute range. Native regression tests exercise both widths, range changes, oldest/newest event access and live additions; chart tests separately cover shared selection, gaps, units and CPU normalization.

`script/benchmark_stats_performance.py` measures the production history view, chart cards and event list together inside a hidden 1,200 × 700 point ScrollView. It injects a frozen clock, controllable hover binding and history-only observable monitor into disposable source copies. Both versions receive the same adapters; no benchmark counters ship in the app. Workloads use 900/3,600 samples and 0/1,000/5,000 events, with five layout pumps and two selection changes before five timed changes per fresh process. Five thousand events is a stress case. Initial chart/event-rule rendering remains proportional to the plotted data even when event rows are lazy.

```sh
python3 script/benchmark_stats_performance.py \
  --paired-baseline /absolute/path/to/before \
  --output output/stats-performance/paired.json \
  --rounds 3 --assert-improvement
```

The Stats gate requires initial event-row evaluations below half the fixture’s event count, plus lower median initial-layout and hover costs for event-heavy workloads. JSON includes all raw timings, row evaluations, source/harness hashes and toolchain. These are native component settlement measurements with a 1 ms run-loop pump, with the same scope limits as the chart benchmark above.

## Long Stats sessions

Collection and presentation have separate lifetimes. Native metrics and monitoring alerts continue at their normal one-second cadence. The visible history publishes an immutable full-hour snapshot for the selected container every five seconds; the range picker and chart marks never observe the shared mutable history. Range changes select from the same coherent hour immediately, without clearing the charts or restarting collection. Container changes refresh immediately. A cached inactive destination or background window cancels its presentation task; visible inactive windows continue updating. The live summary has its own observation scope so metrics cannot invalidate the detail pane's native tab controls. Charts draw cached monotone area/line paths with the existing segment boundaries, downsampling, and full-history cursor lookup.

Each card keeps its series, path and readout caches under one state owner. A lazy locale-aware formatter prepares at most 128 recent plotted values when the immutable projected series changes. Full-resolution cursor values outside that set format on demand; the readout retains at most 256 numeric strings. Locale changes invalidate the strings. A value boundary includes the displayed string, metric and selected/latest mode, so moving between samples with identical displayed values does not rebuild the readout. Cursor geometry and shared selection still use the complete retained history. Native tests cover unchanged numeric values across mode/normalization changes, and formatter tests cover locale switches, rounding, prepared values and cache misses.

The static renderer caches unit-space monotone cubic paths and scales them to the current plot frame when drawing. It preserves extrema and never connects separate history segments. Event rules are batched by kind. Axis labels and the cursor use the same frame and domains, so resizing and inspection stay aligned. This avoids rebuilding the native Charts datum/geometry graph for each snapshot and range change. VoiceOver receives the plotted series, discontinuities, time/unit formatters and events through an [accessibility chart descriptor](https://developer.apple.com/documentation/swiftui/axchartdescriptorrepresentable).

A two-child layout places the same CPU and memory cards side by side when each has 300 points available, and stacks them at narrower widths. It replaces the duplicate card trees previously used as responsive alternatives, reducing snapshot and range-change layout work while retaining each card's cache across resizing.

The history header has its own view boundary. Rebuilding the tagged native picker on every chart snapshot accumulated SwiftUI observation registrations in both the replay and the real app. The header is isolated from snapshots and hover. Its small AppKit representable keeps one native segmented control/coordinator alive while SwiftUI owns the selected range, avoiding new tagged-binding projections during repeated range changes. The sustained replay gates header evaluations against actual range requests.

`StatsHistoryViewTests` includes a native full-hour publication regression, range and scrolling checks at both widths, and repeated inactive/active transitions while collection continues. The publication regression holds the presentation refresh for the test's duration and requires the displayed hour to stay unchanged while collection continues, with median collection settlement below the unchanged 50 ms budget.

Run the sustained native replay against a preserved source tree:

```sh
python3 script/benchmark_stats_soak.py \
  --paired-baseline /absolute/path/to/before \
  --baseline-updates 1000 --updates 172800 \
  --output output/stats-soak/report.json --assert-responsive
```

The fixture compiles the real history and chart source, seeds an hour of history for 20 containers, then advances collection by one virtual second per iteration and presentation by five virtual seconds. It repeatedly changes ranges, shared selection and scroll position, adds limit-change events, and deactivates/reactivates the retained history view. Only the clock, selection binding, monitoring source and measurement counters are injected into disposable source copies. The custom event loop drains autorelease pools on each turn, and a temporary process activity prevents background App Nap from distorting the UI measurement. It checks that both chart drawing callbacks reach the latest data and selected range, inactive views stop publishing, retention stays bounded, and interaction/collection latency and physical footprint stay within budget. Render completion uses a thread-safe diagnostic recorder; neither chart may satisfy the check on behalf of the other. A drawing/range timeout fails immediately. Initial component layout waits for the fixture data to reach the chart, so an empty first frame cannot count as completed rendering.

The strict gate requires each checkpoint's collection median below 50 ms, refresh median and interaction percentiles below 250 ms, and late footprint median within 64 MiB of the warmup median. Range and hover/scroll percentiles are checked separately, and the range maximum must also remain below 250 ms. Reports include main-thread CPU measurements to distinguish application work from scheduling/wait time. Header evaluations must follow range changes rather than presentation refreshes. A failed checkpoint is saved before the runner stops. Preserve timing failures alongside host-pressure evidence; they remain failed wall-clock observations even when the app's original stall signature is absent.

For a focused range burst, keep the same budgets and run `--updates 8000 --range-every 16 --assert-responsive`. This drives 500 native range requests while collection, presentation and activity transitions continue. The lifetime gate counts actual range requests and verifies every scheduled request reached a native picker; increasing interaction density does not relax that gate. The default range cadence remains 1,024 collection ticks.

Results include raw checkpoint data, source and harness hashes, elapsed real time, publication counts, latency distributions and physical footprint. Forty-eight virtual hours are not forty-eight hours of wall-clock uptime or displayed FPS. Also leave the release app running against the local runtime and repeat actual Stats scrolling, range changes and navigation after sustained real uptime. Keep that elapsed duration distinct from the accelerated replay in verification reports.

## Navigation and focused commands

Keep focused-window observation in `ContainerDeskCommands`, rather than on the `App` that constructs the window scenes. The Cleanup action is published by each window. Observing that changing action on the App caused repeated scene reconciliation during menu/accessibility activity: the eleven-container Stacks reproduction produced about seventeen host updates and fifty Stacks body evaluations per switch. Isolating the observer in Commands reduced this to one host update and one or two Stacks evaluations, with measured settlement falling from roughly 0.9–1.8 seconds to 80–96 ms in the same interaction.

The full-app benchmark can select the largest loaded stack instead of inadvertently timing an empty page or a one-container stack. Unlike the component runners, this reads the active local runtime's inventories. It does not start, stop or delete containers. Quit the app before rebuilding its bundle, then run:

```sh
CONTAINERDESK_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build-only
open -n dist/ContainerDesk.app --args \
  --navigation-benchmark --navigation-benchmark-input=keyboard \
  --navigation-benchmark-route=stacks --navigation-benchmark-stack=largest \
  --navigation-benchmark-output=/tmp/containerdesk-stacks.json
```

The short route records four Containers/Stacks round trips, with the first as warmup. Omitting the route option retains the broader sidebar traversal. Omitting the largest-stack option retains the normal selected workspace. Preparation fails clearly if there is no loaded container data for the largest-stack scenario.

Native event timing alone did not reliably expose the focused-command loop. Also repeat sidebar switches with the large stack selected while inspecting the real accessibility hierarchy or interacting with the menu bar. Verify Cleanup routes only to the focused workspace window, retains another window's selection, and is disabled with Settings focused. The before/after counters used to diagnose this were temporary and are not part of normal app launches. Settlement ends at a main-loop boundary; it is not a display-presentation timestamp.

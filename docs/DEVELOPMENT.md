# Developing ContainerDesk

Run the commands below from the repository root. This guide covers source builds,
tests, benchmarks and release maintenance. For app features and setup, see the
[README](../README.md).

CI runs release tests and validates the app bundle; a separate manual workflow covers a dedicated live runtime. See [CI and live integration](CI.md) for runner setup, reports, and branch protection.

```sh
swift test
./script/build_and_run.sh --build-only
```

Run the offline release microbenchmarks with fixture inventories and logs:

```sh
python3 script/benchmark_performance.py --output /private/tmp/containerdesk-performance.json
```

For before-and-after measurements, add `--paired-baseline /path/to/preserved/source-tree`.
The runner compiles both source trees, alternates their execution order across three
rounds, and checks output checksums before comparing medians. It does not contact a
container runtime or download dependencies. These data-processing measurements do
not measure whole-app frame times.

The log responsiveness, chart and metrics-history optimisations have a separate paired runner:

```sh
python3 script/benchmark_remaining_performance.py --paired-baseline /path/to/preserved/source-tree --output /private/tmp/containerdesk-remaining-performance.json
```

This baseline should be the source tree before those optimisations, including the
existing log projection and metrics-history models. The runner distinguishes total
log-filter completion time from main-actor delay. See [Performance verification](PERFORMANCE.md)
for workloads, semantic checks and measurement limits.

The optional read-only cleanup integration check inspects the configured local runtime without deleting resources:

```sh
CONTAINERDESK_CLEANUP_LIVE_READ_CHECK=1 swift test --filter CleanupLiveReadTests
```

The optional profile launch check requires an already-running runtime and a locally cached Linux image with `sh`, `printf`, `cat`, and `sleep`. It launches a uniquely named container and volume, verifies environment snapshots and resource settings, and removes only those generated resources:

```sh
CONTAINERDESK_PROFILES_LIVE_CHECK=1 CONTAINERDESK_PROFILES_IMAGE=docker.io/library/alpine:3.20 swift test --filter EnvironmentProfilesLiveTests
```

The optional `./script/smoke_test.sh` uses uniquely named temporary resources and the already-running builder to exercise container, file, volume, network, export, image build, and OCI archive workflows. It removes only the resources it created. Use `--keep-for-ui` to retain them for manual review; remove only the printed resource names afterward. `./script/plugin_smoke_test.sh` covers the Compose and Kubernetes plugins in the same disposable way.

For an optimized local app bundle, set the build configuration to `release`:

```sh
CONTAINERDESK_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build-only
```

Measure sidebar navigation in the debug app with:

```sh
./script/build_and_run.sh --navigation-benchmark
```

The benchmark drives the sidebar's selection binding through Images, Containers,
Activity, Cleanup, and System. It warms the destinations, measures three further
cycles without accessibility inspection or screenshots, and fails if any warm
switch takes 500 ms or longer. Results are saved to the ignored
`output/navigation-benchmark.json`; set `CONTAINERDESK_NAVIGATION_REPORT` to use
another absolute output path. The metric ends when the main run loop settles
after the destination updates; it does not measure physical display presentation
or completion of asynchronous resource reads. The benchmark performs read-only
navigation and leaves the app open. Use `--navigation-metrics` to log timings
while switching pages manually.

## Architecture

ContainerDesk is a SwiftPM package with two modules:

| Module | Role |
| --- | --- |
| [`ContainerDeskCore`](../Sources/ContainerDeskCore) | CLI client and executable discovery, JSON decoders and resource readers, cleanup, limits recreation and MLX services |
| [`ContainerDeskApp`](../Sources/ContainerDeskApp) | The SwiftUI app: stores, feature screens, and the [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)-based container terminal |

- **Reads are hybrid.** When the installed CLI and API server are verified as matching 1.5.x, container, volume and network lists, plus container inspect and live stats, use Apple’s native API through [`apple/container`](https://github.com/apple/container) and [`apple/containerization`](https://github.com/apple/containerization). Images, registries and machines are read through the CLI, and any failed native read falls back to the CLI. Selecting a CLI path in Settings disables native reads.
- **Changes go through the CLI.** Actions, builds, plugins and terminals run the `container` executable directly, as argv arrays with no shell expansion. The one exception is **Edit Limits**, a separate native stop/backup/delete/create/start transaction gated to exactly 1.5.0.
- **The app never starts or stops the runtime on its own.** Service start and stop are explicit controls on the System screen.

For the exact installed CLI map, important plugin limits, sensitive-data handling and verification status, see [docs/CAPABILITIES.md](CAPABILITIES.md).

## Publishing releases

After changes are ready on `main`, push a semantic version tag to start the release workflow:

```sh
git tag -a v1.0.0 -m "ContainerDesk v1.0.0"
git push origin v1.0.0
```

The workflow tests and builds in release configuration with locked package versions, validates the app bundle, and publishes a GitHub Release with generated notes, a drag-to-Applications DMG, a ZIP, and a SHA-256 checksum for each. Tags such as `v1.0.0-rc.1` are published as prereleases. The downloads are not Developer ID signed or notarized; see [macOS Gatekeeper](../README.md#macos-gatekeeper) before distributing them.

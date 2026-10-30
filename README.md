<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="ContainerDesk app icon">

# ContainerDesk

**A native macOS workspace for Apple’s `container` runtime.**

Browse, run, build, inspect and clean up Linux containers on your Mac with live resource gauges, a built-in terminal and an optional local AI playground, while Apple’s `container` CLI stays the runtime authority.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-555555)](#requirements)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)](Sources/ContainerDeskApp)
[![Apple container 1.5.0](https://img.shields.io/badge/Apple%20container-1.5.0-0A84FF)](docs/CAPABILITIES.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

[Features](#features) · [Screenshots](#screenshots) · [Getting started](#getting-started) · [How it works](#how-it-works) · [Development](#development) · [Capability map](docs/CAPABILITIES.md)

</div>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/hero-light.png">
    <img src="docs/images/hero-light.png" width="100%" alt="ContainerDesk Containers workspace: five storefront containers with live CPU and memory gauges, and the storefront-db detail pane with Overview, Logs, Terminal, Stats, Inspect and Files tabs">
  </picture>
</p>

## Why ContainerDesk

- **One native window for the whole runtime.** Containers, images, volumes, networks, registries, machines, builds, Compose, Kubernetes, system services and cleanup, in searchable SwiftUI tables with inline details.
- **Live, at a glance.** Every container shows CPU and memory against its configured limits. Gauges turn amber at 70% and red at 90%.
- **The CLI stays in charge.** Actions run the real `container` command as an argv array with no shell expansion, with a preview and a record in Activity.
- **Safe by default.** Destructive actions are confirmed and scoped, secrets are redacted from previews and output, and Cleanup never runs bulk prune commands.
- **Local AI built in.** Discover MLX models, serve one on `127.0.0.1`, and chat with it. Conversations stay in memory on your Mac.

## Screenshots

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/terminal.png" alt="Terminal tab showing an interactive shell in the storefront-cache container running redis-cli commands">
      <p align="center"><sub><b>Terminal</b>: an interactive shell inside any running container, next to Logs, Stats, Inspect and Files.</sub></p>
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/cleanup.png" alt="Cleanup screen listing a stopped container selected for removal and an unused volume left unselected">
      <p align="center"><sub><b>Cleanup</b>: review exactly what goes. Stopped containers are pre-selected; volumes with stored data are opt-in.</sub></p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/images/system.png" alt="System screen showing the running runtime service, version, architecture and disk usage by type">
      <p align="center"><sub><b>System</b>: service status, version, disk usage, DNS domains, kernel and properties.</sub></p>
    </td>
    <td width="50%" valign="top">
      <img src="docs/images/images.png" alt="Images screen listing local OCI images with tag, platform and size, with storefront-web selected">
      <p align="center"><sub><b>Images</b>: pull, push, tag, save and load OCI images, or run one straight from its details.</sub></p>
    </td>
  </tr>
</table>

<p align="center">
  <img src="docs/images/local-ai.png" width="80%" alt="MLX Models screen with a Llama 3.2 3B model served locally and a chat exchange in the Chat Playground">
  <br>
  <sub><b>Local AI</b>: run an app-owned MLX-LM server on loopback and chat with it. Prompts and replies stay in memory and never reach Activity or preferences.</sub>
</p>

## Features

### Resources

- Browse containers, images, volumes, networks, registries and machines in searchable native tables with inline resource details. Containers show live CPU and memory usage against configured capacity.
- Run containers in the background, stream logs, inspect redacted metadata, open an interactive terminal, monitor stats, and copy or export files.
- Use **Edit Limits…** on a container to review new CPU and memory limits and recreate it with downtime. The flow backs up the stopped writable disk and boot files, keeps the full launch settings and existing mounts, and restores the prior running/stopped state. A container that has never started can change limits without booting. It attempts restoration if recreation fails. This flow requires the default CLI and API server at exactly 1.5.0 and rejects configurations it cannot preserve safely before stopping them. See [Safety and data handling](#safety-and-data-handling) for how recreation and recovery work.
- Pull, push, tag, save and load OCI images.

### Environment profiles

- Use **Containers → Profiles** to save, edit, duplicate, import and export reusable environment profiles. Profiles retain the image, optional command and container name, ports, mounts, networks, CPU/memory limits, platform, environment-file paths and required variable names. **Review & Run…** opens the full launch form before starting anything. You can also save the current Run form as a profile or load an existing profile there.
- Environment override values entered in Run are transient: saving remembers their names as required variables, not their values. Supply them again when running, or reference an existing UTF-8 environment file using an absolute path or `~/`. Files are read once at launch (up to 1 MiB each); their values are passed transiently and redacted from command previews/output. Explicit overrides take precedence. Quoting and `$` in environment files remain literal, matching the CLI; a bare variable name inherits a value from the app’s environment when available.
- Duplicating a profile clears its container name and opens an editor. Change the ports and volume sources for a separate environment: existing named volumes reuse their data, while new volume names create empty volumes during launch. A profile does not clone a container or its files. Exported JSON includes commands and local path references, so review those before sharing and edit paths after importing on another Mac.

### Development

- Build images with BuildKit and inspect builder controls.
- Create local Compose projects and manage them with the installed plugin’s `up` and `down` commands.
- Create, list, load images into, configure and delete local Kubernetes clusters with the installed experimental plugin.

### Runtime

- Manage runtime service state, logs, disk use, DNS domains, kernel selection and read-only system properties. DNS administration uses macOS’s administrator prompt for only the validated DNS command.
- Use **Cleanup** for a manual scan of unused containers, images, networks and volumes. Eligible stopped containers, unused images and unused networks are selected by default; volumes stay unselected because they contain stored data. Plugin-owned containers are left to their plugin’s dedicated teardown workflow. Review the exact candidates before removal; each selected resource is revalidated and removed individually. Cleanup does not run bulk prune commands.
- **Activity** records the operations you start from every screen, with command previews, timing, state and exit codes. Command output itself is not saved.

### Local AI

- In **Local AI → MLX Models**, discover Hugging Face cache snapshots, import an existing model folder, or explicitly download a public `owner/model` from Hugging Face into ContainerDesk’s managed models folder. ContainerDesk displays the detected version and enables MLX features only when the selected `mlx_lm` executable reports supported version 0.32.2 and exposes the required server options.
- Use the **Running Services** view to discover verified MLX/Jev endpoints already listening on this Mac. It shows model names and loopback endpoints as external, read-only services; ContainerDesk cannot stop them or infer where their model files are stored.
- Start and stop an app-owned MLX inference server explicitly, with one active server per model. It binds only to `127.0.0.1`; use its copied OpenAI-compatible `/v1` endpoint from local clients. The Chat Playground streams replies from that owned server, with per-window in-memory conversations, <kbd>⌘</kbd> <kbd>Return</kbd> to send, Stop Generation, Clear, and Copy Reply.

## Requirements

- Apple silicon Mac running macOS 26 or later.
- Apple `container` CLI 1.5.0 or compatible release, plus its local system service.
- Swift 6.2 or newer.
- Optional local MLX support requires Apple silicon and an existing Python environment with MLX-LM **0.32.2** and Hugging Face Hub installed. The app verifies this exact MLX-LM version and the required local server options; other versions are not currently supported. ContainerDesk does not install Python, MLX-LM, or model weights. See **MLX setup** under [Safety and data handling](#safety-and-data-handling).

## Getting started

1. Install Apple’s [`container`](https://github.com/apple/container) CLI (from its [releases page](https://github.com/apple/container/releases) or Homebrew) and start its system service:

   ```sh
   container system start
   ```

2. Clone, build and launch ContainerDesk:

   ```sh
   git clone https://github.com/MacHatter1/ContainerDesk.git
   cd ContainerDesk
   ./script/build_and_run.sh
   ```

The script builds `dist/ContainerDesk.app`, stages its SwiftPM resource bundles, and opens the app.

| Option | What it does |
| --- | --- |
| *(none)* | Build, stage and open the app |
| `--build-only` | Stage the bundle without closing or opening an app instance |
| `--verify` | Rebuild, open, and confirm the process starts |
| `--debug` | Launch under LLDB |
| `--logs` / `--telemetry` | Open the app and stream its unified logs |

The app discovers the Homebrew CLI from standard install paths and inherited `PATH`. If it cannot find the executable, open **ContainerDesk → Settings** and select it.

### macOS Gatekeeper

The app bundle produced by the build script is not signed with a Developer ID or notarized by Apple. If you download a build, macOS may warn or block the first launch. If you trust the source and have verified the download, try opening the app once, then use **System Settings → Privacy & Security → Open Anyway** if macOS offers that option. Managed Macs may restrict this override. See [Apple’s instructions for opening an unidentified or unnotarized app](https://support.apple.com/en-gb/102445).

## How it works

ContainerDesk is a SwiftPM package with two modules:

| Module | Role |
| --- | --- |
| [`ContainerDeskCore`](Sources/ContainerDeskCore) | CLI client and executable discovery, JSON decoders and resource readers, cleanup, limits recreation and MLX services |
| [`ContainerDeskApp`](Sources/ContainerDeskApp) | The SwiftUI app: stores, feature screens, and the [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)-based container terminal |

- **Reads are hybrid.** When the installed CLI and API server are verified as matching 1.5.x, container, volume and network lists, plus container inspect and live stats, use Apple’s native API through [`apple/container`](https://github.com/apple/container) and [`apple/containerization`](https://github.com/apple/containerization). Images, registries and machines are read through the CLI, and any failed native read falls back to the CLI. Selecting a CLI path in Settings disables native reads.
- **Changes go through the CLI.** Actions, builds, plugins and terminals run the `container` executable directly, as argv arrays with no shell expansion. The one exception is **Edit Limits**, a separate native stop/backup/delete/create/start transaction gated to exactly 1.5.0.
- **The app never starts or stops the runtime on its own.** Service start and stop are explicit controls on the System screen.

For the exact installed CLI map, important plugin limits, sensitive-data handling and verification status, see [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

## Safety and data handling

<details>
<summary><b>Quitting the app</b></summary>

<br>

Quitting ContainerDesk leaves Apple container services and workloads running. It stops only MLX servers and downloads owned by ContainerDesk before exiting; the launcher sends a graceful termination signal and waits up to 10 seconds before replacing a running app. Service start and stop are available explicitly from System.

</details>

<details>
<summary><b>Activity, retries and output buffering</b></summary>

<br>

Command output queues have a fixed capacity. If a consumer cannot keep up, the operation reports an output-buffer error and cancels its owned process instead of accumulating output indefinitely. Activity offers Retry only for known read-only commands; changes must be submitted again through their original flow. Activity keeps all active operations and fills the remaining history slots with recent completed records, targeting 250 records overall. Evicted records release their saved retry requests. Changing the managed models folder keeps active owned models visible so their servers can still be stopped.

</details>

<details>
<summary><b>Edit Limits: recreation and recovery</b></summary>

<br>

Limits recreation requires copy-on-write cloning between the container disk and recovery directory, normally on the same APFS volume. It checks allocated data extents and logical size with a fixed 256 KiB buffer, skipping unallocated disk space. It retains private recovery files in `~/Library/Application Support/ContainerDesk/LimitsRecovery`. These contain the original disk and configuration, including environment values, and may remain boot dependencies of the recreated container. **Do not remove them while that container exists.**

Mounted volume and bind data stays in its original location; the recovery copy does not snapshot those external files. The guest TTY setting is preserved. Process memory, attached terminal sessions, open connections, runtime log history, and automatically assigned network addresses do not survive recreation. Normal Quit is blocked while replacement is active. If the app is force-quit or interrupted, retain the recovery directory and inspect the container before attempting another change; recovery after interruption is manual.

</details>

<details>
<summary><b>MLX setup</b></summary>

<br>

MLX setup is explicit: install Python, [Apple’s MLX-LM 0.32.2](https://github.com/ml-explore/mlx-lm), and [Hugging Face Hub](https://huggingface.co/models) in the same Python environment. Ensure its `mlx_lm` executable is available on `PATH`, or select that executable in Settings; keep the environment’s Python interpreter available for model downloads. If selecting `mlx_lm.server`, its sibling `mlx_lm` executable must be in the same folder; the app uses that sibling for verification and commands, so a standalone server entrypoint is insufficient.

The app does not install dependencies or broaden support to unverified MLX-LM versions. Model downloads are user initiated; cached/imported files are never deleted by ContainerDesk. Forget removes only an imported-folder reference; Move to Trash is offered only for verified ContainerDesk-managed downloads.

</details>

<details>
<summary><b>Chat privacy</b></summary>

<br>

Chat prompts, transcripts, generated replies, download output, and server logs are transient and are not written to Activity or preferences. Conversations are kept separately per window and server session, bounded in memory, and a generation is cancelled when its Chat view closes, the server stops, or the app quits. Closing a window clears its chat state; switching views preserves that window’s conversation. Starting a new server session starts a new conversation. Recent diagnostics retain one inactive session per model, with at most eight inactive sessions overall; older session logs and chat state are released.

</details>

## Development

```sh
swift test
./script/build_and_run.sh --build-only
```

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

## Releases

After changes are ready on `main`, push a semantic version tag to start the release workflow:

```sh
git tag -a v1.0.0 -m "ContainerDesk v1.0.0"
git push origin v1.0.0
```

The workflow runs `swift test`, builds the optimized macOS app, and publishes a GitHub Release with generated notes, a macOS Apple silicon ZIP, and its SHA-256 checksum. Tags such as `v1.0.0-rc.1` are published as prereleases. The release ZIP is not Developer ID signed or notarized; see [macOS Gatekeeper](#macos-gatekeeper) before distributing it.

After downloading both release assets into the same folder, verify the ZIP with:

```sh
shasum -a 256 -c ContainerDesk-v1.0.0-macos-arm64.zip.sha256
```

## License

ContainerDesk is released under the [MIT License](LICENSE). It is provided as is, without warranty of any kind.

---

<sub>Screenshots show the real app with a demo <code>storefront</code> stack on Apple container 1.5.0 and a Llama 3.2 3B model served locally by MLX-LM 0.32.2. ContainerDesk is an independent project and is not affiliated with or endorsed by Apple.</sub>

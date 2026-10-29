# ContainerDesk

ContainerDesk is a native SwiftUI macOS companion for Apple’s `container` CLI. It keeps the CLI as the runtime authority and provides a searchable resource workspace, guided forms for common tasks, typed advanced flags, a terminal, and an Activity view.

## Requirements

- Apple silicon Mac running macOS 26 or later.
- Apple `container` CLI 1.5.0 or compatible release, plus its local system service.
- Swift 6.2 or newer.
- Optional local MLX support requires Apple silicon and an existing Python environment with MLX-LM **0.32.2** and Hugging Face Hub installed. The app verifies this exact MLX-LM version and the required local server options; other versions are not currently supported. ContainerDesk does not install Python, MLX-LM, or model weights.

The app discovers the Homebrew CLI from standard install paths and inherited `PATH`. If it cannot find the executable, open **ContainerDesk → Settings** and select it.

## Build and run

```sh
./script/build_and_run.sh
```

This builds `dist/ContainerDesk.app`, stages its SwiftPM resource bundles, and opens the app. Add `--build-only` to stage it without closing or opening an app instance, or `--verify` to rebuild, open, and confirm the process starts. The script can also launch under LLDB (`--debug`) or stream unified logs (`--logs`, `--telemetry`).

## Development checks

```sh
swift test
./script/build_and_run.sh --build-only
```

The optional read-only cleanup integration check inspects the configured local runtime without deleting resources:

```sh
CONTAINERDESK_CLEANUP_LIVE_READ_CHECK=1 swift test --filter CleanupLiveReadTests
```

The optional `./script/smoke_test.sh` uses uniquely named temporary resources and the already-running builder to exercise container, file, volume, network, export, image build, and OCI archive workflows. It removes only the resources it created. Use `--keep-for-ui` to retain them for manual review; remove only the printed resource names afterward.

## Workflows

- Browse containers, images, volumes, networks, registries and machines in searchable native tables with inline resource details. Containers show live CPU and memory usage against configured capacity.
- Run containers in the background, stream logs, inspect redacted metadata, open an interactive terminal, monitor stats, and copy or export files.
- Use **Edit Limits…** on a container to review new CPU and memory limits and recreate it with downtime. The flow backs up the stopped writable disk and boot files, keeps the full launch settings and existing mounts, and restores the prior running/stopped state. A container that has never started can change limits without booting. It attempts restoration if recreation fails. This flow requires the default CLI and API server at exactly 1.5.0 and rejects configurations it cannot preserve safely before stopping them.
- Pull, push, tag, save and load OCI images; build images with BuildKit and inspect builder controls.
- Create local Compose projects and manage them with the installed plugin’s `up` and `down` commands.
- Create, list, load images into, configure and delete local Kubernetes clusters with the installed experimental plugin.
- Manage runtime service state, logs, disk use, DNS domains, kernel selection and read-only system properties.
- Use **Cleanup** for a manual scan of unused containers, images, networks and volumes. Eligible stopped containers, unused images and unused networks are selected by default; volumes stay unselected because they contain stored data. Plugin-owned containers are left to their plugin's dedicated teardown workflow. Review the exact candidates before removal; each selected resource is revalidated and removed individually. Cleanup does not run bulk prune commands.
- In **Local AI → MLX Models**, discover Hugging Face cache snapshots, import an existing model folder, or explicitly download a public `owner/model` from Hugging Face into ContainerDesk’s managed models folder. ContainerDesk displays the detected version and enables MLX features only when the selected `mlx_lm` executable reports supported version 0.32.2 and exposes the required server options.
- Use the **Running Services** view to discover verified MLX/Jev endpoints already listening on this Mac. It shows model names and loopback endpoints as external, read-only services; ContainerDesk cannot stop them or infer where their model files are stored.
- Start and stop an app-owned MLX inference server explicitly, with one active server per model. It binds only to `127.0.0.1`; use its copied OpenAI-compatible `/v1` endpoint from local clients. The Chat Playground streams replies from that owned server, with per-window in-memory conversations, Cmd-Return to send, Stop Generation, Clear, and Copy Reply.

Quitting ContainerDesk leaves Apple container services and workloads running. It stops only MLX servers and downloads owned by ContainerDesk before exiting; the launcher sends a graceful termination signal and waits up to 10 seconds before replacing a running app. Service start and stop are available explicitly from System. DNS administration uses macOS’s administrator prompt for only the validated DNS command.

Limits recreation requires copy-on-write cloning between the container disk and recovery directory, normally on the same APFS volume. It checks allocated data extents and logical size with a fixed 256 KiB buffer, skipping unallocated disk space. It retains private recovery files in `~/Library/Application Support/ContainerDesk/LimitsRecovery`. These contain the original disk and configuration, including environment values, and may remain boot dependencies of the recreated container. Do not remove them while that container exists. Mounted volume and bind data stays in its original location; the recovery copy does not snapshot those external files. The guest TTY setting is preserved. Process memory, attached terminal sessions, open connections, runtime log history, and automatically assigned network addresses do not survive recreation. Normal Quit is blocked while replacement is active. If the app is force-quit or interrupted, retain the recovery directory and inspect the container before attempting another change; recovery after interruption is manual.

MLX setup is explicit: install Python, [Apple’s MLX-LM 0.32.2](https://github.com/ml-explore/mlx-lm), and [Hugging Face Hub](https://huggingface.co/models) in the same Python environment. Ensure its `mlx_lm` executable is available on `PATH`, or select that executable in Settings; keep the environment’s Python interpreter available for model downloads. If selecting `mlx_lm.server`, its sibling `mlx_lm` executable must be in the same folder; the app uses that sibling for verification and commands, so a standalone server entrypoint is insufficient. The app does not install dependencies or broaden support to unverified MLX-LM versions. Model downloads are user initiated; cached/imported files are never deleted by ContainerDesk. Forget removes only an imported-folder reference; Move to Trash is offered only for verified ContainerDesk-managed downloads.

Chat prompts, transcripts, generated replies, download output, and server logs are transient and are not written to Activity or preferences. Conversations are kept separately per window and server session, bounded in memory, and a generation is cancelled when its Chat view closes, the server stops, or the app quits. Closing a window clears its chat state; switching views preserves that window's conversation. Starting a new server session starts a new conversation. Recent diagnostics retain one inactive session per model, with at most eight inactive sessions overall; older session logs and chat state are released.

Command output queues have a fixed capacity. If a consumer cannot keep up, the operation reports an output-buffer error and cancels its owned process instead of accumulating output indefinitely. Activity offers Retry only for known read-only commands; changes must be submitted again through their original flow. Activity keeps all active operations and fills the remaining history slots with recent completed records, targeting 250 records overall. Evicted records release their saved retry requests. Changing the managed models folder keeps active owned models visible so their servers can still be stopped.

For the exact installed CLI map, important plugin limits, sensitive-data handling and verification status, see [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

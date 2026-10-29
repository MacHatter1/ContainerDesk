#!/usr/bin/env bash
set -euo pipefail
umask 077

MODE="all"
case "${1:-}" in
  "") ;;
  --compose-only) MODE="compose" ;;
  --k8s-only) MODE="k8s" ;;
  *) echo "usage: $0 [--compose-only|--k8s-only]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo "usage: $0 [--compose-only|--k8s-only]" >&2; exit 2; fi

CLI="${CONTAINER_CLI:-/opt/homebrew/bin/container}"
if [[ ! -x "$CLI" ]]; then CLI="$(command -v container || true)"; fi
if [[ -z "$CLI" || ! -x "$CLI" ]]; then echo "container CLI not found; set CONTAINER_CLI" >&2; exit 1; fi

UUID="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/cut -c1-8)"
PREFIX="containerdesk-plugin-smoke-${UUID}"
COMPOSE_PROJECT="$PREFIX"
K8S_NAME="${PREFIX}-k8s"
K8S_IMAGE="${CONTAINERDESK_K8S_IMAGE:-alpine:3.20}"
K8S_NODE_IMAGE="${CONTAINERDESK_K8S_NODE_IMAGE:-docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95}"
TEMP_DIR="$(/usr/bin/mktemp -d /private/tmp/containerdesk-plugin-smoke.XXXXXX)"
COMPOSE_FILE="$TEMP_DIR/compose.yaml"
KUBECONFIG_FILE="$TEMP_DIR/kubeconfig"
WRITE_CONFIG_FILE="$TEMP_DIR/written-kubeconfig"
COMMAND_OUTPUT="$TEMP_DIR/command-output"
LOG_FILE="$TEMP_DIR/smoke.log"
DEFAULT_KUBECONFIG="$HOME/.kube/config"
DEFAULT_KUBECONFIG_HASH=""
COMPOSE_MAY_EXIST=0
K8S_MAY_EXIST=0
COMPOSE_PASSED=0
K8S_PASSED=0

record() {
  printf '%s\n' "$*" >> "$LOG_FILE"
  local size
  size="$(/usr/bin/stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
  if [[ "$size" -gt 1048576 ]]; then
    /usr/bin/tail -c 1048576 "$LOG_FILE" > "$TEMP_DIR/log-trimmed"
    /bin/mv "$TEMP_DIR/log-trimmed" "$LOG_FILE"
  fi
}

file_hash() {
  if [[ -f "$1" ]]; then /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; else printf 'absent'; fi
}

run_compose() {
  local label="$1"; shift
  record "Compose: $label"
  if "$CLI" compose "$@" > "$COMMAND_OUTPUT" 2>&1; then
    record "Compose $label: passed"
    /usr/bin/tail -c 65536 "$COMMAND_OUTPUT" >> "$LOG_FILE" || true
  else
    local status=$?
    record "Compose $label: failed (exit $status)"
    /usr/bin/tail -c 8192 "$COMMAND_OUTPUT" >> "$LOG_FILE" || true
    return "$status"
  fi
}

run_k8s() {
  local label="$1"; shift
  record "Kubernetes: $label"
  if KUBECONFIG="$KUBECONFIG_FILE" "$CLI" k8s "$@" > "$COMMAND_OUTPUT" 2>&1; then
    record "Kubernetes $label: passed"
  else
    local status=$?
    # Do not place kubeconfig or certificate-bearing plugin output in the log.
    record "Kubernetes $label: failed (exit $status; command output suppressed)"
    return "$status"
  fi
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ "$COMPOSE_MAY_EXIST" -eq 1 ]]; then
    "$CLI" compose down --file "$COMPOSE_FILE" --project-name "$COMPOSE_PROJECT" > /dev/null 2>&1 || true
    record "Compose cleanup: requested down for only $COMPOSE_PROJECT"
  fi
  if [[ "$K8S_MAY_EXIST" -eq 1 ]]; then
    KUBECONFIG="$KUBECONFIG_FILE" "$CLI" k8s delete --name "$K8S_NAME" > /dev/null 2>&1 || true
    record "Kubernetes cleanup: requested delete for only $K8S_NAME"
  fi
  local after_hash
  after_hash="$(file_hash "$DEFAULT_KUBECONFIG")"
  if [[ "$after_hash" != "$DEFAULT_KUBECONFIG_HASH" ]]; then
    echo "ERROR: the default kubeconfig hash changed during the smoke run." >&2
    record "Default kubeconfig hash: changed"
    exit_code=1
  else
    record "Default kubeconfig hash: unchanged"
  fi
  echo "Plugin smoke checks:"
  /usr/bin/grep -E '^(Run prefix:|Container service preflight:|Compose .*: (passed|failed)|Kubernetes .*: (passed|failed)|Kubernetes list:|Default kubeconfig hash:)' "$LOG_FILE" || true
  if [[ "$COMPOSE_PASSED" -eq 1 ]]; then echo "Compose smoke passed (unique project $COMPOSE_PROJECT)."; fi
  if [[ "$K8S_PASSED" -eq 1 ]]; then echo "Kubernetes smoke passed (unique cluster $K8S_NAME; isolated KUBECONFIG)."; fi
  if [[ "$COMPOSE_PASSED" -eq 0 && "$K8S_PASSED" -eq 0 && "$exit_code" -eq 0 ]]; then echo "No plugin smoke workflow was selected."; fi
  if [[ "$exit_code" -ne 0 ]]; then
    echo "Plugin smoke failed; only the named resources above were targeted." >&2
    if [[ "$MODE" != "k8s" ]]; then
      echo "Last bounded Compose output (up to 8 KB):" >&2
      /usr/bin/tail -c 8192 "$LOG_FILE" >&2 || true
    fi
  fi
  /bin/rm -rf "$TEMP_DIR"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$TEMP_DIR/kube"
DEFAULT_KUBECONFIG_HASH="$(file_hash "$DEFAULT_KUBECONFIG")"
record "Run prefix: $PREFIX"
record "Default kubeconfig hash: captured"
if ! "$CLI" system status > "$COMMAND_OUTPUT" 2>&1; then
  echo "Container services are unavailable; the smoke harness will not start them." >&2
  exit 1
fi
record "Container service preflight: passed (read-only)"

if [[ "$MODE" != "k8s" ]]; then
  cat > "$COMPOSE_FILE" <<'YAML'
services:
  smoke:
    image: redis:7.2.4-alpine
    command: ["sleep", "120"]
YAML
  COMPOSE_MAY_EXIST=1
  run_compose "up dry-run" up --file "$COMPOSE_FILE" --project-name "$COMPOSE_PROJECT" --pull missing --force-recreate --keep-orphans --dry-run
  run_compose "up" up --file "$COMPOSE_FILE" --project-name "$COMPOSE_PROJECT" --pull missing --force-recreate --keep-orphans
  run_compose "down dry-run" down --file "$COMPOSE_FILE" --project-name "$COMPOSE_PROJECT" --keep-networks --dry-run
  run_compose "down" down --file "$COMPOSE_FILE" --project-name "$COMPOSE_PROJECT" --keep-networks
  COMPOSE_PASSED=1
fi

if [[ "$MODE" != "compose" ]]; then
  # The experimental plugin needs its pinned node image. Pull only this official, digest-pinned image if absent.
  if ! "$CLI" image inspect "$K8S_NODE_IMAGE" > "$COMMAND_OUTPUT" 2>&1; then
    record "Kubernetes node image: missing; pulling the configured digest-pinned image"
    if "$CLI" image pull --platform linux/arm64 "$K8S_NODE_IMAGE" > "$COMMAND_OUTPUT" 2>&1; then
      record "Kubernetes node image pull: passed (linux/arm64, digest-pinned)"
    else
      echo "Could not pull the digest-pinned Kubernetes node image; no cluster was created." >&2
      exit 1
    fi
  else
    record "Kubernetes node image: already present (digest-pinned)"
  fi
  # Require the workload image to already exist locally; only the pinned node image above may be pulled.
  if ! "$CLI" image inspect "$K8S_IMAGE" > "$COMMAND_OUTPUT" 2>&1; then
    echo "Kubernetes smoke needs an existing local image ($K8S_IMAGE); set CONTAINERDESK_K8S_IMAGE." >&2
    exit 1
  fi
  : > "$KUBECONFIG_FILE"
  K8S_MAY_EXIST=1
  run_k8s "create" create --name "$K8S_NAME" --node-image "$K8S_NODE_IMAGE" --cpus 2 --memory 2G
  local_list="$TEMP_DIR/k8s-list"
  if ! KUBECONFIG="$KUBECONFIG_FILE" "$CLI" k8s list > "$local_list" 2> "$COMMAND_OUTPUT"; then
    record "Kubernetes list: failed (command output suppressed)"
    exit 1
  fi
  if ! /usr/bin/grep -Fq "$K8S_NAME" "$local_list"; then
    record "Kubernetes list: did not include the unique cluster name"
    exit 1
  fi
  record "Kubernetes list: passed; unique cluster found"
  run_k8s "load existing local image" load-image --name "$K8S_NAME" "$K8S_IMAGE"
  run_k8s "write config to alternate path" write-config --name "$K8S_NAME" --kubeconfig "$WRITE_CONFIG_FILE"
  if [[ ! -s "$WRITE_CONFIG_FILE" ]]; then
    record "Kubernetes write-config: output file was not created"
    exit 1
  fi
  run_k8s "delete unique cluster" delete --name "$K8S_NAME"
  K8S_MAY_EXIST=0
  K8S_PASSED=1
fi

record "All selected plugin checks passed."

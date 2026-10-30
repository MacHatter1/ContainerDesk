#!/usr/bin/env bash
set -euo pipefail

KEEP_FOR_UI=0
if [[ "${1:-}" == "--keep-for-ui" ]]; then KEEP_FOR_UI=1; elif [[ $# -gt 0 ]]; then echo "usage: $0 [--keep-for-ui]" >&2; exit 2; fi

CLI="${CONTAINER_CLI:-/opt/homebrew/bin/container}"
if [[ ! -x "$CLI" ]]; then CLI="$(command -v container || true)"; fi
if [[ -z "$CLI" || ! -x "$CLI" ]]; then echo "container CLI not found; set CONTAINER_CLI" >&2; exit 1; fi

SUFFIX="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/cut -c1-8)"
NAME="containerdesk-smoke-$SUFFIX"
NETWORK="${NAME}-net"
VOLUME="${NAME}-vol"
MANIFEST_DIR="$(/usr/bin/mktemp -d /private/tmp/containerdesk-smoke.XXXXXX)"
MANIFEST="$MANIFEST_DIR/resources.txt"
HOST_FILE="$(/usr/bin/mktemp /private/tmp/containerdesk-copy.XXXXXX)"
BUILD_CONTEXT="$MANIFEST_DIR/build-context"
IMAGE="containerdesk-smoke-$SUFFIX:build"
IMAGE_TAG="containerdesk-smoke-$SUFFIX:tagged"
NETWORK_MAY_EXIST=0
VOLUME_MAY_EXIST=0
CONTAINER_MAY_EXIST=0
IMAGE_MAY_EXIST=0
IMAGE_TAG_MAY_EXIST=0

cleanup_step() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    return 0
  else
    local cleanup_status=$?
    echo "Smoke cleanup failed: $description (exit $cleanup_status)." >&2
    return "$cleanup_status"
  fi
}

# A creating command can fail after its side effect, so cleanup tracks intent.
# A failed delete is harmless only when a fresh, well-formed inventory proves absence.
cleanup_resource() {
  local kind="$1" target="$2" delete_status
  shift 2
  if "$@" >/dev/null 2>&1; then return 0; else delete_status=$?; fi
  local inventory="$MANIFEST_DIR/cleanup-inventory.json"
  local list_args=()
  case "$kind" in
    container) list_args=(list --all --format json) ;;
    image) list_args=(image list --format json --verbose) ;;
    volume) list_args=(volume list --format json) ;;
    network) list_args=(network list --format json) ;;
    *) return 1 ;;
  esac
  if "$CLI" "${list_args[@]}" > "$inventory" 2>/dev/null && /usr/bin/python3 - "$inventory" "$kind" "$target" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "rb") as stream:
        payload = stream.read(2_000_001)
    if len(payload) > 2_000_000:
        raise ValueError("incomplete inventory")
    rows = json.loads(payload)
    if not isinstance(rows, list):
        raise ValueError("invalid inventory")
    names = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid row")
        config = row.get("configuration", {})
        if not isinstance(config, dict):
            raise ValueError("invalid configuration")
        name = (config.get("id") or row.get("id")) if sys.argv[2] == "container" else config.get("name")
        if not isinstance(name, str) or not name:
            raise ValueError("missing identity")
        names.append(name)
        if sys.argv[2] == "image":
            # Apple CLI 1.5 keeps the canonical reference in configuration.name
            # and resolves its active default registry in displayReference.
            # Compare both spellings; missing display metadata cannot prove
            # that a failed deletion of an unqualified tag was harmless.
            display = row.get("displayReference")
            if not isinstance(display, str) or not display:
                raise ValueError("missing image display reference")
            names.append(display)
    sys.exit(0 if sys.argv[3] not in names else 1)
except (ValueError, OSError):
    sys.exit(1)
PY
  then
    return 0
  fi
  echo "Smoke cleanup failed: delete $kind $target (exit $delete_status; absence could not be verified)." >&2
  return "$delete_status"
}

cleanup() {
  local exit_code=$?
  local cleanup_failed=0
  trap - EXIT INT TERM
  if [[ "$KEEP_FOR_UI" -eq 0 ]]; then
    if [[ "$CONTAINER_MAY_EXIST" -eq 1 ]]; then
      "$CLI" stop --time 1 -- "$NAME" >/dev/null 2>&1 || true
      cleanup_resource container "$NAME" "$CLI" delete --force -- "$NAME" || cleanup_failed=1
    fi
    if [[ "$IMAGE_TAG_MAY_EXIST" -eq 1 ]]; then
      cleanup_resource image "$IMAGE_TAG" "$CLI" image delete --force -- "$IMAGE_TAG" || cleanup_failed=1
    fi
    if [[ "$IMAGE_MAY_EXIST" -eq 1 ]]; then
      cleanup_resource image "$IMAGE" "$CLI" image delete --force -- "$IMAGE" || cleanup_failed=1
    fi
    if [[ "$VOLUME_MAY_EXIST" -eq 1 ]]; then
      cleanup_resource volume "$VOLUME" "$CLI" volume delete -- "$VOLUME" || cleanup_failed=1
    fi
    if [[ "$NETWORK_MAY_EXIST" -eq 1 ]]; then
      cleanup_resource network "$NETWORK" "$CLI" network delete -- "$NETWORK" || cleanup_failed=1
    fi
    cleanup_step "remove host file $HOST_FILE" /bin/rm -f "$HOST_FILE" || cleanup_failed=1
    cleanup_step "remove temporary directory $MANIFEST_DIR" /bin/rm -rf "$MANIFEST_DIR" || cleanup_failed=1
    if [[ "$cleanup_failed" -eq 1 ]]; then
      echo "Smoke cleanup incomplete; inspect only the resources logged for this run." >&2
      if [[ "$exit_code" -eq 0 ]]; then exit_code=1; fi
    elif [[ "$exit_code" -eq 0 ]]; then
      echo "Smoke checks and cleanup passed."
    fi
  fi
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$MANIFEST" <<EOF
container=$NAME
network=$NETWORK
volume=$VOLUME
image=$IMAGE
image_tag=$IMAGE_TAG
host_copy=$HOST_FILE
image_archive=$MANIFEST_DIR/image.tar
EOF
echo "Smoke resources for this run:"
cat "$MANIFEST"
echo "Manifest: $MANIFEST"

"$CLI" system status >/dev/null
# Never let a smoke build implicitly create or reconfigure a builder. Use only
# the already-running user builder; fail before building if it is unavailable.
"$CLI" builder status --format json > "$MANIFEST_DIR/builder-status.json"
/usr/bin/python3 - "$MANIFEST_DIR/builder-status.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    entries = json.load(stream)
if not isinstance(entries, list) or not any(
    item.get("id") == "buildkit" and item.get("status", {}).get("state") == "running"
    for item in entries if isinstance(item, dict)
):
    raise SystemExit("Smoke build requires the existing buildkit builder to be running; no builder was started or changed.")
PY
NETWORK_MAY_EXIST=1
"$CLI" network create "$NETWORK" >/dev/null
VOLUME_MAY_EXIST=1
"$CLI" volume create "$VOLUME" >/dev/null
printf 'ContainerDesk smoke %s\n' "$SUFFIX" > "$HOST_FILE"
CONTAINER_MAY_EXIST=1
"$CLI" run --detach --name "$NAME" --cpus 1 --memory 256M --network "$NETWORK" --volume "$VOLUME:/tmp/containerdesk" alpine:3.20 sh -c 'while true; do echo containerdesk-smoke; sleep 1; done' >/dev/null

"$CLI" inspect "$NAME" >/dev/null
"$CLI" logs -n 5 "$NAME" >/dev/null
"$CLI" stats --format json --no-stream "$NAME" >/dev/null
"$CLI" exec "$NAME" sh -c 'test -d /tmp/containerdesk && echo exec-ok' >/dev/null
"$CLI" copy "$HOST_FILE" "$NAME:/tmp/containerdesk-host-copy.txt"
"$CLI" exec "$NAME" cat /tmp/containerdesk-host-copy.txt | /usr/bin/grep -q "ContainerDesk smoke $SUFFIX"
"$CLI" export --output "$MANIFEST_DIR/container.tar" "$NAME"

/bin/mkdir -p "$BUILD_CONTEXT"
printf 'ContainerDesk smoke image %s\n' "$SUFFIX" > "$BUILD_CONTEXT/marker.txt"
cat > "$BUILD_CONTEXT/Containerfile" <<'EOF'
FROM scratch
COPY marker.txt /marker.txt
EOF
IMAGE_MAY_EXIST=1
"$CLI" build --tag "$IMAGE" "$BUILD_CONTEXT"
IMAGE_TAG_MAY_EXIST=1
"$CLI" image tag "$IMAGE" "$IMAGE_TAG"
"$CLI" image inspect "$IMAGE_TAG" >/dev/null
"$CLI" image save --output "$MANIFEST_DIR/image.tar" "$IMAGE_TAG"
"$CLI" image load --input "$MANIFEST_DIR/image.tar" --force

if [[ "$KEEP_FOR_UI" -eq 1 ]]; then
  echo "Smoke resources retained for UI review. Container: $NAME"
  echo "Clean up only these named resources after review: $NAME, $VOLUME, $NETWORK, $IMAGE, $IMAGE_TAG"
else
  echo "Smoke checks completed; cleaning only $NAME, $VOLUME, $NETWORK, $IMAGE and $IMAGE_TAG."
fi

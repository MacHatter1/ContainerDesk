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
CREATED_NETWORK=0
CREATED_VOLUME=0
CREATED_CONTAINER=0
CREATED_IMAGE=0
CREATED_IMAGE_TAG=0

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

cleanup() {
  local exit_code=$?
  local cleanup_failed=0
  trap - EXIT INT TERM
  if [[ "$KEEP_FOR_UI" -eq 0 ]]; then
    if [[ "$CREATED_CONTAINER" -eq 1 ]]; then
      cleanup_step "stop container $NAME" "$CLI" stop --time 1 "$NAME" || cleanup_failed=1
      cleanup_step "delete container $NAME" "$CLI" delete --force "$NAME" || cleanup_failed=1
    fi
    if [[ "$CREATED_IMAGE_TAG" -eq 1 ]]; then
      cleanup_step "delete image $IMAGE_TAG" "$CLI" image delete --force "$IMAGE_TAG" || cleanup_failed=1
    fi
    if [[ "$CREATED_IMAGE" -eq 1 ]]; then
      cleanup_step "delete image $IMAGE" "$CLI" image delete --force "$IMAGE" || cleanup_failed=1
    fi
    if [[ "$CREATED_VOLUME" -eq 1 ]]; then
      cleanup_step "delete volume $VOLUME" "$CLI" volume delete "$VOLUME" || cleanup_failed=1
    fi
    if [[ "$CREATED_NETWORK" -eq 1 ]]; then
      cleanup_step "delete network $NETWORK" "$CLI" network delete "$NETWORK" || cleanup_failed=1
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
"$CLI" network create "$NETWORK" >/dev/null
CREATED_NETWORK=1
"$CLI" volume create "$VOLUME" >/dev/null
CREATED_VOLUME=1
printf 'ContainerDesk smoke %s\n' "$SUFFIX" > "$HOST_FILE"
"$CLI" run --detach --name "$NAME" --cpus 1 --memory 256M --network "$NETWORK" --volume "$VOLUME:/tmp/containerdesk" alpine:3.20 sh -c 'while true; do echo containerdesk-smoke; sleep 1; done' >/dev/null
CREATED_CONTAINER=1

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
"$CLI" build --tag "$IMAGE" "$BUILD_CONTEXT"
CREATED_IMAGE=1
"$CLI" image tag "$IMAGE" "$IMAGE_TAG"
CREATED_IMAGE_TAG=1
"$CLI" image inspect "$IMAGE_TAG" >/dev/null
"$CLI" image save --output "$MANIFEST_DIR/image.tar" "$IMAGE_TAG"
"$CLI" image load --input "$MANIFEST_DIR/image.tar" --force

if [[ "$KEEP_FOR_UI" -eq 1 ]]; then
  echo "Smoke resources retained for UI review. Container: $NAME"
  echo "Clean up only these named resources after review: $NAME, $VOLUME, $NETWORK, $IMAGE, $IMAGE_TAG"
else
  echo "Smoke checks completed; cleaning only $NAME, $VOLUME, $NETWORK, $IMAGE and $IMAGE_TAG."
fi

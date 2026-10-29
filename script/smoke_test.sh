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

cleanup() {
  local exit_code=$?
  if [[ "$KEEP_FOR_UI" -eq 0 ]]; then
    if [[ "$CREATED_CONTAINER" -eq 1 ]]; then "$CLI" stop --time 1 "$NAME" >/dev/null 2>&1 || true; "$CLI" delete --force "$NAME" >/dev/null 2>&1 || true; fi
    if [[ "$CREATED_IMAGE_TAG" -eq 1 ]]; then "$CLI" image delete --force "$IMAGE_TAG" >/dev/null 2>&1 || true; fi
    if [[ "$CREATED_IMAGE" -eq 1 ]]; then "$CLI" image delete --force "$IMAGE" >/dev/null 2>&1 || true; fi
    if [[ "$CREATED_VOLUME" -eq 1 ]]; then "$CLI" volume delete "$VOLUME" >/dev/null 2>&1 || true; fi
    if [[ "$CREATED_NETWORK" -eq 1 ]]; then "$CLI" network delete "$NETWORK" >/dev/null 2>&1 || true; fi
    /bin/rm -f "$HOST_FILE"
    /bin/rm -rf "$MANIFEST_DIR"
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

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

cat > "$MANIFEST" <<EOF
container=$NAME
network=$NETWORK
volume=$VOLUME
image=alpine:3.20
host_copy=$HOST_FILE
image_tag=$IMAGE_TAG
image_archive=$MANIFEST_DIR/image.tar
EOF

if [[ "$KEEP_FOR_UI" -eq 1 ]]; then
  echo "Smoke resources retained for UI review. Container: $NAME"
  echo "Manifest: $MANIFEST"
  echo "Clean up only these named resources after review: $NAME, $VOLUME, $NETWORK, $IMAGE, $IMAGE_TAG"
else
  echo "Smoke checks passed; cleaning only $NAME, $VOLUME, $NETWORK, $IMAGE and $IMAGE_TAG."
fi

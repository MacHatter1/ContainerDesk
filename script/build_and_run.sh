#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ContainerDesk"
BUNDLE_ID="com.thomasswift.ContainerDesk"
MIN_SYSTEM_VERSION="26.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_ICON="$ROOT_DIR/Sources/ContainerDeskApp/Resources/ContainerDesk.icns"

if [[ ! -f "$APP_ICON" ]]; then
  echo "Missing app icon: $APP_ICON" >&2
  exit 1
fi

if [[ "$MODE" != "--build-only" && "$MODE" != "build-only" ]]; then
  EXISTING_PIDS="$(pgrep -x "$APP_NAME" || true)"
  if [[ -n "$EXISTING_PIDS" ]]; then
    while IFS= read -r PID; do
      [[ -n "$PID" ]] && kill -TERM "$PID" 2>/dev/null || true
    done <<<"$EXISTING_PIDS"

    for _ in {1..40}; do
      if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then break; fi
      sleep 0.25
    done

    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      echo "$APP_NAME did not finish graceful shutdown within 10 seconds; refusing to replace its running bundle." >&2
      exit 1
    fi
  fi
fi
swift build
BUILD_BIN_PATH="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>ContainerDesk</string>
<key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
APP_RESOURCES="$APP_CONTENTS/Resources"
mkdir -p "$APP_RESOURCES"
cp "$APP_ICON" "$APP_RESOURCES/ContainerDesk.icns"
shopt -s nullglob
for RESOURCE_BUNDLE in "$BUILD_BIN_PATH"/*.bundle; do
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
done

case "$MODE" in
  --build-only|build-only) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *) echo "usage: $0 [run|--build-only|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

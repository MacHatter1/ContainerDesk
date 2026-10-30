#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo "usage: $0 [app-bundle-path]" >&2
  exit 2
fi
APP_BUNDLE="${1:-$ROOT_DIR/dist/ContainerDesk.app}"
PLIST="$APP_BUNDLE/Contents/Info.plist"
RESOURCES="$APP_BUNDLE/Contents/Resources"

fail() { echo "Invalid app bundle '$APP_BUNDLE': $*" >&2; exit 1; }
[[ -d "$APP_BUNDLE" ]] || fail "app directory is missing"
[[ -f "$PLIST" ]] || fail "Contents/Info.plist is missing"
/usr/bin/plutil -lint "$PLIST" >/dev/null 2>&1 || fail "Contents/Info.plist is invalid"

check_plist_value() {
  local key="$1" expected="$2" actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null)" || fail "Info.plist is missing $key"
  [[ "$actual" == "$expected" ]] || fail "Info.plist $key must be '$expected' (found '$actual')"
}
check_plist_value CFBundleExecutable ContainerDesk
check_plist_value CFBundleIdentifier com.thomasswift.ContainerDesk
check_plist_value CFBundleName ContainerDesk
check_plist_value CFBundlePackageType APPL
check_plist_value CFBundleIconFile ContainerDesk
check_plist_value LSMinimumSystemVersion 26.0

BINARY="$APP_BUNDLE/Contents/MacOS/ContainerDesk"
[[ -f "$BINARY" && -x "$BINARY" ]] || fail "executable Contents/MacOS/ContainerDesk is missing or not executable"
ARCHS="$(/usr/bin/lipo -archs "$BINARY" 2>/dev/null)" || fail "executable is not a valid Mach-O binary"
[[ " $ARCHS " == *" arm64 "* ]] || fail "executable must include arm64 (found: $ARCHS)"
[[ -s "$RESOURCES/ContainerDesk.icns" ]] || fail "icon Contents/Resources/ContainerDesk.icns is missing or empty"

# Resource bundles emitted by the pinned SwiftPM dependency graph. Update this
# list when Package.resolved changes the resources required by the executable.
for bundle in \
  ContainerDesk_ContainerDeskApp \
  SwiftProtobuf_SwiftProtobuf \
  swift-crypto_CCryptoBoringSSL \
  swift-crypto_CCryptoBoringSSLShims \
  swift-crypto_Crypto \
  swift-crypto_CryptoBoringWrapper \
  swift-crypto_CryptoExtras \
  swift-nio-ssl_NIOSSL \
  swift-nio_NIOPosix \
  swift-nio__NIOFileSystem; do
  bundle_contents="$RESOURCES/$bundle.bundle/Contents"
  [[ -f "$bundle_contents/Info.plist" && -d "$bundle_contents/Resources" ]] || fail "required SwiftPM resource bundle $bundle.bundle is missing or incomplete"
  if [[ "$bundle" != ContainerDesk_ContainerDeskApp ]]; then
    [[ -s "$bundle_contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "$bundle.bundle is missing PrivacyInfo.xcprivacy"
  fi
done
[[ -s "$RESOURCES/ContainerDesk_ContainerDeskApp.bundle/Contents/Resources/ContainerDesk.icns" ]] || fail "app's SwiftPM resource bundle is missing ContainerDesk.icns"
echo "Validated app bundle: $APP_BUNDLE"

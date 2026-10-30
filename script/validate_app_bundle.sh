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

# The build records the actual SwiftPM output so packaged copies can be
# checked without the build directory. Swift Build uses Contents/Resources;
# native SwiftPM copies resources to the bundle root.
INVENTORY="$RESOURCES/SwiftPMResourceBundles.txt"
[[ -s "$INVENTORY" ]] || fail "SwiftPM resource bundle inventory is missing or empty"
declared_bundles=" "
app_bundle_found=false
while IFS= read -r bundle || [[ -n "$bundle" ]]; do
  [[ "$bundle" =~ ^[A-Za-z0-9_.-]+\.bundle$ && "$bundle" != .* ]] || fail "invalid SwiftPM resource bundle name in inventory: '$bundle'"
  [[ "$declared_bundles" != *" $bundle "* ]] || fail "duplicate SwiftPM resource bundle in inventory: $bundle"
  declared_bundles+="$bundle "
  bundle_path="$RESOURCES/$bundle"
  [[ -d "$bundle_path" ]] || fail "required SwiftPM resource bundle $bundle is missing"
  if [[ -d "$bundle_path/Contents" ]]; then
    bundle_resources="$bundle_path/Contents/Resources"
    bundle_plist="$bundle_path/Contents/Info.plist"
    [[ -f "$bundle_plist" ]] || fail "$bundle is missing Contents/Info.plist"
  else
    bundle_resources="$bundle_path"
    bundle_plist="$bundle_path/Info.plist"
  fi
  if [[ -f "$bundle_plist" ]]; then
    /usr/bin/plutil -lint "$bundle_plist" >/dev/null 2>&1 || fail "$bundle has an invalid Info.plist"
  fi
  if [[ "$bundle" == ContainerDesk_ContainerDeskApp.bundle ]]; then
    app_bundle_found=true
    [[ -s "$bundle_resources/ContainerDesk.icns" ]] || fail "$bundle is missing ContainerDesk.icns"
    [[ -s "$bundle_resources/README.txt" ]] || fail "$bundle is missing README.txt"
  else
    [[ -s "$bundle_resources/PrivacyInfo.xcprivacy" ]] || fail "$bundle is missing PrivacyInfo.xcprivacy"
  fi
done < "$INVENTORY"
[[ "$app_bundle_found" == true ]] || fail "SwiftPM resource bundle inventory does not list ContainerDesk_ContainerDeskApp.bundle"
echo "Validated app bundle: $APP_BUNDLE"

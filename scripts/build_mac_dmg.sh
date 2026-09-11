#!/bin/bash
set -euo pipefail

# Open-core macOS DMG: signed + notarized.
# The host app stays sandboxed. The Packet Tunnel system extension does not:
# it runs as root and must read the user App Group (config, pins, logs).
# Run from anywhere; script lives in the PrizmX app repo.
#
# Usage:
#   ./scripts/build_mac_dmg.sh [VERSION]
#
# Required environment variables:
#   CERT_NAME                  or APPLE_CERT_NAME
#   APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD
#   APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD
#   APPLE_PROVISION_APP_BASE64 / APPLE_PROVISION_TUNNEL_BASE64
#
# Optional:
#   APP_NAME                   default: PrizmX
#   BUILD_NUMBER               default: git rev-list --count HEAD
#   SKIP_FINDER_LAYOUT         1/true (CI)
#   KEYCHAIN_PASSWORD
#
# VERSION: first argument, or TAG_VERSION / GITHUB_REF_NAME (leading "v" stripped)
#
# Layout: the app repo, PrizmX-Foundation, PrizmX-Kit, and SwiftTCP must be
# siblings (local workspace or CI checkouts). Packet Tunnel is signed inside-out;
# do not use codesign --deep.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$APP_REPO/.." && pwd)"
cd "$WORKSPACE_ROOT"

CERT_NAME="${CERT_NAME:-${APPLE_CERT_NAME:-}}"

APP_NAME="${APP_NAME:-PrizmX}"
VERSION="${1:-${TAG_VERSION:-${GITHUB_REF_NAME:-}}}"
VERSION="${VERSION#v}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${2:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$APP_REPO" rev-list --count HEAD)}"

APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-$APP_REPO/PrizmX/PrizmX.entitlements}"
TUNNEL_ENTITLEMENTS="${TUNNEL_ENTITLEMENTS:-$APP_REPO/PacketTunnel/PacketTunnel.entitlements}"
PROJECT="$APP_REPO/PrizmX.xcodeproj"
SCHEME="PrizmX"
CONFIGURATION="Release"

BUILD_DIR="$APP_REPO/build"
ARCHIVE_PATH="$BUILD_DIR/PrizmX.xcarchive"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
TMP_DMG="$BUILD_DIR/${APP_NAME}.tmp.dmg"
DMG_NAME="${APP_NAME}_macos_v${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
BACKGROUND_IMG="$APP_REPO/assets/dmg/background.png"
MOUNT_DIR="/Volumes/${APP_NAME}"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "❌ Missing required environment variable: $name"
    exit 1
  fi
}

skip_flag() {
  local value="${1:-}"
  [ "$value" = "1" ] || [ "$value" = "true" ]
}

if [ -z "$VERSION" ]; then
  echo "❌ VERSION is required (pass as \$1, TAG_VERSION, or GITHUB_REF_NAME)."
  echo "   Example: ./scripts/build_mac_dmg.sh 0.1.0"
  exit 1
fi

require_env CERT_NAME

require_env APPLE_ID
require_env APPLE_TEAM_ID
if [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
  echo "❌ APPLE_APP_SPECIFIC_PASSWORD is required for notarization."
  exit 1
fi
require_env APPLE_CERTIFICATE_BASE64
require_env APPLE_CERTIFICATE_PASSWORD

for sibling in PrizmX-Foundation PrizmX-Kit SwiftTCP; do
  if [ ! -d "$WORKSPACE_ROOT/$sibling" ]; then
    echo "❌ Missing sibling checkout: $WORKSPACE_ROOT/$sibling"
    echo "   Open-core build expects Foundation, Kit, and SwiftTCP next to the app repo."
    exit 1
  fi
done

if [ ! -f "$APP_ENTITLEMENTS" ] || [ ! -f "$TUNNEL_ENTITLEMENTS" ]; then
  echo "❌ Entitlements not found:"
  echo "   $APP_ENTITLEMENTS"
  echo "   $TUNNEL_ENTITLEMENTS"
  exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$DERIVED_DATA" "$TMP_DMG" "$DMG_PATH"

PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)

SIGNING_KEYCHAIN=""
PREV_DEFAULT_KEYCHAIN=""
PREV_KEYCHAIN_LIST=()
cleanup_signing() {
  # Restore the user's keychain search list first: install_signing_from_env
  # replaces it with just the temp signing keychain, and leaving that state
  # behind detaches login.keychain-db (apps then spam keychain prompts and
  # Xcode reports "private key is not installed").
  if [ ${#PREV_KEYCHAIN_LIST[@]} -gt 0 ]; then
    security list-keychain -d user -s "${PREV_KEYCHAIN_LIST[@]}" >/dev/null 2>&1 || true
  fi
  if [ -n "${PREV_DEFAULT_KEYCHAIN:-}" ]; then
    security default-keychain -s "$PREV_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  fi
}
trap cleanup_signing EXIT

decode_profile() {
  local provision="$1"
  local out="$2"
  security cms -D -i "$provision" >"$out"
}

profile_buddy() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

profile_app_id_file() {
  local id
  id="$(profile_buddy "$1" 'Entitlements:com.apple.application-identifier')"
  if [ -z "$id" ]; then
    id="$(profile_buddy "$1" 'Entitlements:application-identifier')"
  fi
  printf '%s' "$id"
}

install_profile_b64() {
  local b64="$1"
  local label="$2"
  if [ -z "$b64" ]; then
    return 1
  fi
  local tmp plist uuid
  tmp="$(mktemp)"
  plist="$(mktemp)"
  printf '%s' "$b64" | base64 --decode >"$tmp"
  decode_profile "$tmp" "$plist"
  uuid="$(profile_buddy "$plist" UUID)"
  local dir
  for dir in "${PROFILE_DIRS[@]}"; do
    mkdir -p "$dir"
    cp "$tmp" "$dir/${uuid}.mobileprovision"
  done
  rm -f "$tmp" "$plist"
  echo "▶ Installed $label ($uuid)"
  return 0
}

remove_profiles_for_bundle() {
  local bundle="$1"
  local dir f plist appid
  plist="$(mktemp)"
  for dir in "${PROFILE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      decode_profile "$f" "$plist" || continue
      appid="$(profile_app_id_file "$plist")"
      if [ "$appid" = "$bundle" ] || [[ "$appid" == *".${bundle}" ]]; then
        rm -f "$f"
      fi
    done
  done
  rm -f "$plist"
}

install_signing_from_env() {
  if [ -n "${APPLE_CERTIFICATE_BASE64:-}" ]; then
    if [ -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]; then
      echo "❌ APPLE_CERTIFICATE_PASSWORD is required with APPLE_CERTIFICATE_BASE64"
      exit 1
    fi
    SIGNING_KEYCHAIN="$(mktemp "${TMPDIR:-/tmp}/prizmx-signing.XXXXXX.keychain-db")"
    rm -f "$SIGNING_KEYCHAIN"
    local kc_pass="${KEYCHAIN_PASSWORD:-$SIGNING_KEYCHAIN}"
    local cert_path
    cert_path="$(mktemp)"
    printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode >"$cert_path"
    security create-keychain -p "$kc_pass" "$SIGNING_KEYCHAIN"
    security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
    security unlock-keychain -p "$kc_pass" "$SIGNING_KEYCHAIN"
    security import "$cert_path" \
      -P "$APPLE_CERTIFICATE_PASSWORD" \
      -A -t cert -f pkcs12 \
      -T /usr/bin/codesign -T /usr/bin/security \
      -k "$SIGNING_KEYCHAIN"
    local ca_dir ca
    ca_dir="$(mktemp -d)"
    curl -fsSL "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer" \
      -o "$ca_dir/DeveloperIDG2CA.cer"
    curl -fsSL "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer" \
      -o "$ca_dir/AppleRootCA-G3.cer"
    for ca in "$ca_dir"/*.cer; do
      security import "$ca" -k "$SIGNING_KEYCHAIN" -A >/dev/null || true
    done
    rm -rf "$ca_dir"
    while IFS= read -r kc; do
      kc="$(printf '%s' "$kc" | tr -d '"' | xargs)"
      [ -n "$kc" ] && PREV_KEYCHAIN_LIST+=("$kc")
    done < <(security list-keychain -d user)
    security list-keychain -d user -s \
      "$SIGNING_KEYCHAIN" /Library/Keychains/System.keychain
    PREV_DEFAULT_KEYCHAIN="$(security default-keychain | tr -d '"' | xargs)"
    security default-keychain -s "$SIGNING_KEYCHAIN"
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s -k "$kc_pass" "$SIGNING_KEYCHAIN"
    rm -f "$cert_path"
    echo "▶ Imported APPLE_CERTIFICATE_BASE64 into temporary keychain"
  fi
  remove_profiles_for_bundle "app.prizmx.macos"
  remove_profiles_for_bundle "app.prizmx.macos.packet-tunnel"
  install_profile_b64 "${APPLE_PROVISION_APP_BASE64:-}" APPLE_PROVISION_APP_BASE64 || true
  install_profile_b64 "${APPLE_PROVISION_TUNNEL_BASE64:-}" APPLE_PROVISION_TUNNEL_BASE64 || true
}

resolve_profile() {
  local bundle="$1"
  local team="${APPLE_TEAM_ID:-}"
  local want="${team}.${bundle}"
  local dir f plist appid name uuid
  plist="$(mktemp)"
  for dir in "${PROFILE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      decode_profile "$f" "$plist" || continue
      appid="$(profile_app_id_file "$plist")"
      if [ "$appid" != "$want" ] && [ "$appid" != "$bundle" ]; then
        continue
      fi
      uuid="$(profile_buddy "$plist" UUID)"
      name="$(profile_buddy "$plist" Name)"
      rm -f "$plist"
      printf '%s\t%s\n' "$uuid" "$name"
      return 0
    done
  done
  rm -f "$plist"
  return 1
}

dump_profiles() {
  echo "▶ Installed provisioning profiles:"
  local dir f plist appid name uuid
  plist="$(mktemp)"
  for dir in "${PROFILE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    echo "  $dir"
    for f in "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      decode_profile "$f" "$plist" || continue
      uuid="$(profile_buddy "$plist" UUID)"
      name="$(profile_buddy "$plist" Name)"
      appid="$(profile_app_id_file "$plist")"
      echo "    $name uuid=$uuid id=$appid"
    done
  done
  rm -f "$plist"
}

# ============================================================
# Build. Do not pass ENABLE_APP_SANDBOX=NO — that would unsandbox the host app.
# Packet Tunnel sandbox is off via its target / entitlements file.
# ============================================================

echo "▶ Archiving $APP_NAME $VERSION ($BUILD_NUMBER)…"
install_signing_from_env
dump_profiles

APP_BUNDLE_ID="app.prizmx.macos"
TUNNEL_BUNDLE_ID="app.prizmx.macos.packet-tunnel"
APP_PROFILE_LINE="$(resolve_profile "$APP_BUNDLE_ID" || true)"
TUNNEL_PROFILE_LINE="$(resolve_profile "$TUNNEL_BUNDLE_ID" || true)"
if [ -z "$APP_PROFILE_LINE" ] || [ -z "$TUNNEL_PROFILE_LINE" ]; then
  echo "❌ Need Developer ID profiles for:"
  echo "   $APP_BUNDLE_ID"
  echo "   $TUNNEL_BUNDLE_ID"
  echo "   (application-identifier = TEAMID.bundle-id)"
  exit 1
fi
PRIZMX_APP_PROFILE_UUID="${APP_PROFILE_LINE%%$'\t'*}"
PRIZMX_APP_PROFILE_SPECIFIER="${APP_PROFILE_LINE#*$'\t'}"
PRIZMX_TUNNEL_PROFILE_UUID="${TUNNEL_PROFILE_LINE%%$'\t'*}"
PRIZMX_TUNNEL_PROFILE_SPECIFIER="${TUNNEL_PROFILE_LINE#*$'\t'}"
echo "▶ App profile: $PRIZMX_APP_PROFILE_SPECIFIER ($PRIZMX_APP_PROFILE_UUID)"
echo "▶ Tunnel profile: $PRIZMX_TUNNEL_PROFILE_SPECIFIER ($PRIZMX_TUNNEL_PROFILE_UUID)"

XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  -archivePath "$ARCHIVE_PATH"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGN_IDENTITY="-"
  ENABLE_HARDENED_RUNTIME=YES
)
xcodebuild "${XCODEBUILD_ARGS[@]}" archive

if [ ! -d "$APP_PATH" ]; then
  echo "❌ App not found at $APP_PATH"
  exit 1
fi

# ============================================================
# Sign inside-out (system extension before host; never --deep)
# ============================================================

profile_path_for_uuid() {
  local uuid="$1"
  local dir
  for dir in "${PROFILE_DIRS[@]}"; do
    if [ -f "$dir/${uuid}.mobileprovision" ]; then
      echo "$dir/${uuid}.mobileprovision"
      return 0
    fi
  done
  return 1
}

sign_item() {
  local path="$1"
  local entitlements="${2:-}"
  local args=(--force --options runtime --timestamp --sign "$CERT_NAME")
  if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
    args+=(--keychain "$SIGNING_KEYCHAIN")
  fi
  if [ -n "$entitlements" ]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$path"
}

FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"
if [ -d "$FRAMEWORKS_PATH" ]; then
  echo "▶ Signing embedded frameworks and dylibs…"
  while IFS= read -r item; do
    sign_item "$item"
  done < <(find "$FRAMEWORKS_PATH" \( -name "*.framework" -o -name "*.dylib" \) | sort)
fi

SYSEX_DIR="$APP_PATH/Contents/Library/SystemExtensions"
SYSEX_PATH="$SYSEX_DIR/app.prizmx.macos.packet-tunnel.systemextension"
if [ ! -d "$SYSEX_PATH" ]; then
  echo "❌ System extension missing at $SYSEX_PATH"
  ls -la "$SYSEX_DIR" 2>/dev/null || true
  exit 1
fi

APP_PROFILE_FILE="$(profile_path_for_uuid "$PRIZMX_APP_PROFILE_UUID")"
TUNNEL_PROFILE_FILE="$(profile_path_for_uuid "$PRIZMX_TUNNEL_PROFILE_UUID")"
mkdir -p "$APP_PATH/Contents" "$SYSEX_PATH/Contents"
cp "$APP_PROFILE_FILE" "$APP_PATH/Contents/embedded.provisionprofile"
cp "$TUNNEL_PROFILE_FILE" "$SYSEX_PATH/Contents/embedded.provisionprofile"

echo "▶ Signing Packet Tunnel system extension…"
sign_item "$SYSEX_PATH" "$TUNNEL_ENTITLEMENTS"

echo "▶ Signing main App bundle…"
sign_item "$APP_PATH" "$APP_ENTITLEMENTS"

echo "▶ Verifying code signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "▶ Entitlements (app sandboxed, tunnel not):"
APP_ENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
TUN_ENTS="$(codesign -d --entitlements :- "$SYSEX_PATH" 2>/dev/null || true)"
echo "$APP_ENTS" | grep -E "app-sandbox|networkextension" || true
echo "$TUN_ENTS" | grep -E "app-sandbox|networkextension" || true
echo "$APP_ENTS" | grep -q "app-sandbox" || {
  echo "❌ Host app lost app-sandbox"
  exit 1
}
if echo "$TUN_ENTS" | grep -q "app-sandbox"; then
  echo "❌ Packet Tunnel must not be sandboxed (cannot read user App Group)"
  exit 1
fi

# ============================================================
# Notarize app
# ============================================================

if ! skip_flag "${SKIP_NOTARIZE:-}"; then
  echo "▶ Creating ZIP for notarization…"
  ZIP_NAME="$BUILD_DIR/${APP_NAME}.zip"
  rm -f "$ZIP_NAME"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_NAME"

  echo "▶ Submitting app for notarization…"
  xcrun notarytool submit "$ZIP_NAME" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo "▶ Stapling notarization ticket to app…"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  rm -f "$ZIP_NAME"

  echo "▶ Gatekeeper assessment (app)…"
  spctl --assess --type execute --verbose "$APP_PATH"
else
  echo "ℹ️  SKIP_NOTARIZE: skipping app notarization."
fi

# ============================================================
# Create DMG
# ============================================================

echo "▶ Preparing temp DMG directory…"
DMG_DIR="$(mktemp -d)"
ditto "$APP_PATH" "$DMG_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_DIR/Applications"

echo "▶ Creating writable DMG…"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -fs APFS \
  -ov -format UDRW \
  "$TMP_DMG"

rm -rf "$DMG_DIR"

echo "▶ Mounting writable DMG…"
hdiutil attach "$TMP_DMG" -mountpoint "$MOUNT_DIR"

if [ -f "$BACKGROUND_IMG" ]; then
  echo "▶ Setting background…"
  mkdir -p "$MOUNT_DIR/.background"
  cp "$BACKGROUND_IMG" "$MOUNT_DIR/.background/background.png"
else
  echo "ℹ️  Background image not found ($BACKGROUND_IMG); skipping."
fi

if ! skip_flag "${SKIP_FINDER_LAYOUT:-}"; then
  echo "▶ Configuring Finder window…"
  BACKGROUND_LINE=""
  if [ -f "$BACKGROUND_IMG" ]; then
    BACKGROUND_LINE='set background picture of viewOptions to file ".background:background.png"'
  fi
  osascript <<EOF || echo "ℹ️  Finder layout timed out; continuing."
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false

    set the bounds of container window to {100, 100, 740, 520}

    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    $BACKGROUND_LINE

    set position of item "$APP_NAME.app" to {160, 200}
    set position of item "Applications" to {480, 200}

    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF
else
  echo "ℹ️  Skipping Finder DMG layout (SKIP_FINDER_LAYOUT)."
fi

echo "▶ Unmounting RW DMG…"
hdiutil detach "$MOUNT_DIR"

echo "▶ Converting to compressed read-only DMG…"
hdiutil convert "$TMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov -o "$DMG_PATH"

rm -f "$TMP_DMG"

echo "✅ DMG ready: $DMG_PATH"

# ============================================================
# Sign + notarize DMG
# ============================================================

echo "▶ Signing DMG…"
codesign --force --timestamp --sign "$CERT_NAME" "$DMG_PATH"
codesign --verify --verbose "$DMG_PATH"

if ! skip_flag "${SKIP_NOTARIZE:-}"; then
  echo "▶ Notarizing DMG…"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait

  echo "▶ Stapling notarization ticket to DMG…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "▶ Verifying app inside DMG with Gatekeeper…"
  DMG_VERIFY_MOUNT="$(mktemp -d)/dmg-verify"
  mkdir -p "$DMG_VERIFY_MOUNT"
  (
    hdiutil attach -nobrowse -readonly "$DMG_PATH" -mountpoint "$DMG_VERIFY_MOUNT"
    trap 'hdiutil detach "$DMG_VERIFY_MOUNT" >/dev/null 2>&1 || true' EXIT
    spctl --assess --type execute --verbose "$DMG_VERIFY_MOUNT/${APP_NAME}.app"
  )
else
  echo "ℹ️  SKIP_NOTARIZE: skipping DMG notarization."
fi

echo ""
echo "✅ Build complete!"
echo "-----------------------------------"
echo " App : $APP_PATH"
echo " DMG : $DMG_PATH"
echo ""
echo "▶ Test on a clean Mac:"
echo "  1. Copy DMG to another Mac"
echo "  2. Open DMG"
echo "  3. Drag app to /Applications"
echo "  4. Double-click app"
echo ""

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "dmg_path=$DMG_PATH" >>"$GITHUB_OUTPUT"
fi

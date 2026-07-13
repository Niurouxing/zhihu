#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$IOS_DIR/.." && pwd)"
PROJECT_PATH="$IOS_DIR/iosApp.xcodeproj"
SCHEME="${SCHEME:-iosApp}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT_DIR/build/iosApp/iosApp.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT_DIR/build/iosApp/export}"
EXPORT_METHOD="${EXPORT_METHOD:-debugging}"

"$SCRIPT_DIR/preflight.sh"

ARCHIVE_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  -allowProvisioningUpdates
)

if [[ -n "${TEAM_ID:-}" ]]; then
  ARCHIVE_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi
if [[ -n "${BUNDLE_ID:-}" ]]; then
  ARCHIVE_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"

ARCHIVE_ARGS+=(archive)
xcodebuild "${ARCHIVE_ARGS[@]}"

if [[ -n "${EXPORT_OPTIONS_PLIST:-}" ]]; then
  EXPORT_OPTIONS="$EXPORT_OPTIONS_PLIST"
else
  EXPORT_OPTIONS="$(mktemp "${TMPDIR:-/tmp}/zhihu-plus-plus-export-options.XXXXXX.plist")"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
    printf '%s\n' '  <key>method</key>'
    printf '  <string>%s</string>\n' "$EXPORT_METHOD"
    printf '%s\n' '  <key>signingStyle</key>'
    printf '%s\n' '  <string>automatic</string>'
    if [[ -n "${TEAM_ID:-}" ]]; then
      printf '%s\n' '  <key>teamID</key>'
      printf '  <string>%s</string>\n' "$TEAM_ID"
    fi
    printf '%s\n' '  <key>stripSwiftSymbols</key>'
    printf '%s\n' '  <true/>'
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
  } >"$EXPORT_OPTIONS"
fi

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

printf 'Exported IPA artifacts to %s\n' "$EXPORT_PATH"

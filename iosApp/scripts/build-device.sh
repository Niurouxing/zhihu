#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$IOS_DIR/iosApp.xcodeproj"
SCHEME="${SCHEME:-iosApp}"
CONFIGURATION="${CONFIGURATION:-Debug}"

"$SCRIPT_DIR/preflight.sh"

if [[ -n "${DEVICE_ID:-}" ]]; then
  DESTINATION="platform=iOS,id=$DEVICE_ID"
else
  DESTINATION="${DESTINATION:-generic/platform=iOS}"
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -allowProvisioningUpdates
)

if [[ -n "${TEAM_ID:-}" ]]; then
  XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi
if [[ -n "${BUNDLE_ID:-}" ]]; then
  XCODEBUILD_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID")
fi

XCODEBUILD_ARGS+=(build)
xcodebuild "${XCODEBUILD_ARGS[@]}"

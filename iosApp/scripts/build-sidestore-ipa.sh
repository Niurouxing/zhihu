#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$IOS_DIR/.." && pwd)"
PROJECT_PATH="$IOS_DIR/iosApp.xcodeproj"
SCHEME="${SCHEME:-iosApp}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE_ID="${BUNDLE_ID:-com.github.kangyun1994.zhplus.swift}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/iosApp/sidestore}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$OUTPUT_DIR/DerivedData}"
IPA_PATH="${IPA_PATH:-$OUTPUT_DIR/ZhihuPlusPlus-SideStore.ipa}"
PACKAGE_DIR="$OUTPUT_DIR/package"
PAYLOAD_DIR="$PACKAGE_DIR/Payload"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

command -v zip >/dev/null 2>&1 || fail "zip is not available"

BUNDLE_ID="$BUNDLE_ID" SCHEME="$SCHEME" SKIP_TEAM_ID_WARNING=1 "$SCRIPT_DIR/preflight.sh"

mkdir -p "$OUTPUT_DIR" "$DERIVED_DATA_PATH"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products"
[[ -d "$PRODUCTS_DIR" ]] || fail "missing Xcode products directory at $PRODUCTS_DIR"

APP_PATHS=()
while IFS= read -r app_path; do
  APP_PATHS+=("$app_path")
done < <(find "$PRODUCTS_DIR" -type d -name "*.app" -path "*/$CONFIGURATION-iphoneos/*.app" -print | sort)

if [[ "${#APP_PATHS[@]}" -eq 0 ]]; then
  while IFS= read -r app_path; do
    APP_PATHS+=("$app_path")
  done < <(find "$PRODUCTS_DIR" -type d -name "*.app" -path "*-iphoneos/*.app" -print | sort)
fi

if [[ "${#APP_PATHS[@]}" -eq 0 ]]; then
  fail "no .app product found under $PRODUCTS_DIR/*-iphoneos"
fi

if [[ "${#APP_PATHS[@]}" -gt 1 ]]; then
  printf 'error: multiple .app products found under %s:\n' "$PRODUCTS_DIR" >&2
  printf '  %s\n' "${APP_PATHS[@]}" >&2
  fail "set CONFIGURATION or clean $DERIVED_DATA_PATH before rerunning"
fi

APP_PATH="${APP_PATHS[0]}"

rm -rf "$PACKAGE_DIR" "$IPA_PATH"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/"

(
  cd "$PACKAGE_DIR"
  zip -qry "$IPA_PATH" Payload
)

rm -rf "$PACKAGE_DIR"

info "SideStore IPA: $IPA_PATH"
info "Bundle identifier: $BUNDLE_ID"

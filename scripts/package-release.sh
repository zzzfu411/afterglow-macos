#!/bin/zsh
# Package an already-built app. This script never signs code or stores credentials.
set -euo pipefail
export LC_ALL=C
umask 077

ROOT="${0:A:h:h}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/package-release.sh preview <app> [output-directory]
  scripts/package-release.sh release <app> <team-id> <notary-profile> [output-directory]

preview: verify the existing signature and create a clearly labelled preview ZIP.
release: require Developer ID signing and WidgetKit, submit to Apple using an
         existing notarytool Keychain profile, staple, validate, then create a ZIP.

Default output: .build/packages
Existing archives are never overwritten. No GitHub upload is performed.
USAGE
}

fail() { print -u2 -- "Error: $*"; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
MODE="${1:-}"
case "$MODE" in
  preview)
    (( $# == 2 || $# == 3 )) || { usage >&2; exit 2; }
    OUTPUT_DIR="${3:-$ROOT/.build/packages}"
    ;;
  release)
    (( $# == 4 || $# == 5 )) || { usage >&2; exit 2; }
    TEAM_ID="$3"
    NOTARY_PROFILE="$4"
    [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Team ID must contain 10 uppercase letters or digits."
    [[ -n "$NOTARY_PROFILE" && "$NOTARY_PROFILE" != -* && "$NOTARY_PROFILE" != *$'\n'* && "$NOTARY_PROFILE" != *$'\r'* ]] || fail "Provide an existing notarytool Keychain profile name."
    OUTPUT_DIR="${5:-$ROOT/.build/packages}"
    ;;
  *) usage >&2; exit 2 ;;
esac

APP_PATH="${2:A}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
[[ -d "$APP_PATH" && "$APP_PATH" == *.app && -f "$APP_PATH/Contents/Info.plist" ]] || fail "Input must be a built .app bundle."
[[ "$OUTPUT_DIR/" != "$APP_PATH/"* ]] || fail "Output directory cannot be inside the input app."
/bin/mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(/usr/bin/mktemp -d "$OUTPUT_DIR/.afterglow-package.XXXXXX")"
cleanup() { [[ -z "${WORK_DIR:-}" ]] || /bin/rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGED_APP="$WORK_DIR/${APP_PATH:t}"
/usr/bin/ditto "$APP_PATH" "$STAGED_APP"
INFO="$STAGED_APP/Contents/Info.plist"
VERSION="$(plist_value "$INFO" CFBundleShortVersionString)" || fail "Missing app version."
BUILD_NUMBER="$(plist_value "$INFO" CFBundleVersion)" || fail "Missing build number."
for component in "$VERSION" "$BUILD_NUMBER"; do
  [[ "$component" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Version and build must be safe filename components."
done

executable_path() {
  local bundle="$1" executable
  executable="$(plist_value "$bundle/Contents/Info.plist" CFBundleExecutable)" || fail "Missing executable in ${bundle:t}."
  [[ -n "$executable" && "$executable" != */* && "$executable" != "." && "$executable" != ".." ]] || fail "Invalid bundle executable."
  [[ -f "$bundle/Contents/MacOS/$executable" && -x "$bundle/Contents/MacOS/$executable" ]] || fail "Missing executable in ${bundle:t}."
  print -r -- "$bundle/Contents/MacOS/$executable"
}

MAIN_EXECUTABLE="$(executable_path "$STAGED_APP")"
ARCHS="$(/usr/bin/lipo -archs "$MAIN_EXECUTABLE")" || fail "The app executable must be Mach-O."
case "$ARCHS" in
  arm64|x86_64) ARCH_LABEL="$ARCHS" ;;
  "arm64 x86_64"|"x86_64 arm64") ARCH_LABEL="universal" ;;
  *) fail "Unsupported app architecture: $ARCHS" ;;
esac
ARCHIVE_NAME="Afterglow-$VERSION-build$BUILD_NUMBER-$ARCH_LABEL-$MODE.zip"
FINAL_ZIP="$OUTPUT_DIR/$ARCHIVE_NAME"
[[ ! -e "$FINAL_ZIP" && ! -L "$FINAL_ZIP" ]] || fail "Archive already exists: $FINAL_ZIP"

# --deep is appropriate for verification; do not use it to re-sign nested code.
/usr/bin/codesign --verify --deep --strict --all-architectures "$STAGED_APP" || fail "The copied app has an invalid signature; rebuild it first."

if [[ "$MODE" == "release" ]]; then
  REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""
  /usr/bin/codesign --verify --strict --all-architectures --test-requirement "=$REQUIREMENT" "$STAGED_APP" || fail "A release requires Developer ID Application signing from Team $TEAM_ID; ad-hoc and development signatures are not accepted."
  SHARED_GROUP="$(plist_value "$INFO" AfterglowAppGroup)" || fail "Missing App Group configuration."
  [[ "$SHARED_GROUP" == "$TEAM_ID".* && "$SHARED_GROUP" != *'$('* ]] || fail "App Group must use the configured Team ID prefix."

  verify_distribution_bundle() {
    local bundle="$1" executable bundle_archs arch details entitlements group index found debug_access
    /usr/bin/codesign --verify --strict --all-architectures --test-requirement "=$REQUIREMENT" "$bundle" || fail "${bundle:t} needs a valid Developer ID Application signature from Team $TEAM_ID."
    executable="$(executable_path "$bundle")"
    bundle_archs="$(/usr/bin/lipo -archs "$executable")"
    [[ "${(j: :)${(os: :)bundle_archs}}" == "${(j: :)${(os: :)ARCHS}}" ]] || fail "${bundle:t} and the main app must support the same architectures."
    [[ "$(plist_value "$bundle/Contents/Info.plist" AfterglowAppGroup)" == "$SHARED_GROUP" ]] || fail "${bundle:t} has a different App Group."
    [[ "$(plist_value "$bundle/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" && "$(plist_value "$bundle/Contents/Info.plist" CFBundleVersion)" == "$BUILD_NUMBER" ]] || fail "${bundle:t} has a different version or build number."

    for arch in ${(s: :)bundle_archs}; do
      details="$(/usr/bin/codesign --display --verbose=4 --arch "$arch" "$bundle" 2>&1)" || fail "Cannot inspect ${bundle:t}."
      [[ "$details" == *$'\n'"TeamIdentifier=$TEAM_ID"$'\n'* ]] || fail "${bundle:t} has a different signature Team ID."
      [[ "$details" =~ 'flags=0x[[:xdigit:]]+\([^)]*runtime[^)]*\)' ]] || fail "${bundle:t} must enable Hardened Runtime for $arch."
      [[ "$details" == *$'\n'Timestamp=* ]] || fail "${bundle:t} needs a secure signing timestamp for $arch."
      entitlements="$WORK_DIR/entitlements.plist"
      /usr/bin/codesign --display --arch "$arch" --entitlements :- "$bundle" > "$entitlements" 2>/dev/null || fail "Cannot inspect signed entitlements."
      /usr/bin/plutil -lint -s "$entitlements" || fail "Invalid signed entitlements in ${bundle:t}."
      debug_access="$(plist_value "$entitlements" com.apple.security.get-task-allow || true)"
      [[ -z "$debug_access" || "$debug_access" == "false" ]] || fail "${bundle:t} still allows debugger attachment; export a distribution build."
      [[ "$(plist_value "$entitlements" com.apple.security.app-sandbox || true)" == "true" ]] || fail "${bundle:t} must retain its App Sandbox entitlement."
      index=0
      found=false
      while group="$(plist_value "$entitlements" "com.apple.security.application-groups:$index")"; do
        [[ "$group" != "$SHARED_GROUP" ]] || found=true
        index=$((index + 1))
      done
      [[ "$found" == true ]] || fail "${bundle:t} is missing the shared App Group entitlement."
    done
  }

  verify_distribution_bundle "$STAGED_APP"
  EXTENSIONS=("$STAGED_APP"/Contents/**/*.appex(N/))
  (( ${#EXTENSIONS} > 0 )) || fail "A release must embed the WidgetKit extension; the local preview cannot be notarized as a full release."
  WIDGET_COUNT=0
  for extension in "${EXTENSIONS[@]}"; do
    verify_distribution_bundle "$extension"
    if [[ "$(plist_value "$extension/Contents/Info.plist" NSExtension:NSExtensionPointIdentifier || true)" == "com.apple.widgetkit-extension" ]]; then
      WIDGET_COUNT=$((WIDGET_COUNT + 1))
    fi
  done
  (( WIDGET_COUNT > 0 )) || fail "No embedded WidgetKit extension was found."
  /usr/bin/xcrun --find notarytool >/dev/null || fail "Install a toolchain that includes notarytool."
  /usr/bin/xcrun --find stapler >/dev/null || fail "Install a toolchain that includes stapler."

  LOG_DIR="$OUTPUT_DIR/notary-logs"
  /bin/mkdir -p "$LOG_DIR"
  SUBMISSION_RESULT="$LOG_DIR/submit-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$.json"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$WORK_DIR/submit.zip"
  print -- "Submitting to Apple using the existing Keychain profile; the source app stays unchanged."
  SUBMISSION_EXIT=0
  /usr/bin/xcrun notarytool submit "$WORK_DIR/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m --output-format json --no-progress > "$SUBMISSION_RESULT" || SUBMISSION_EXIT=$?
  SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$SUBMISSION_RESULT" 2>/dev/null || true)"
  NOTARY_STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_RESULT" 2>/dev/null || true)"
  LOG_SAVED=false
  if [[ "$SUBMISSION_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    NOTARY_LOG="$LOG_DIR/$SUBMISSION_ID.json"
    # Keep rejection diagnostics too. An in-progress submission has no log yet.
    if /usr/bin/xcrun notarytool log "$SUBMISSION_ID" "$NOTARY_LOG" --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
      LOG_SAVED=true
    fi
  fi
  if (( SUBMISSION_EXIT != 0 )) || [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    fail "Notarization failed or timed out. No release archive was created. Inspect $SUBMISSION_RESULT and $LOG_DIR; an uploaded job may still be processing."
  fi
  [[ "$LOG_SAVED" == true ]] || fail "Could not retrieve the notarization log; no release archive was created."
  /usr/bin/xcrun stapler staple "$STAGED_APP"
  /usr/bin/xcrun stapler validate "$STAGED_APP"
  /usr/bin/codesign --verify --deep --strict --all-architectures "$STAGED_APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$STAGED_APP"
  print -- "Notarization accepted, ticket validated, and Gatekeeper assessment passed. Review $NOTARY_LOG for warnings."
else
  print -- "Preview only: no notarization or Gatekeeper acceptance is claimed."
fi

# ZIP files cannot carry a stapled ticket themselves. Repack the verified,
# stapled app only after all release checks have passed.
TEMP_ZIP="$WORK_DIR/$ARCHIVE_NAME"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$TEMP_ZIP"
/usr/bin/unzip -tq "$TEMP_ZIP" >/dev/null
DIGEST="$(/usr/bin/shasum -a 256 "$TEMP_ZIP")"
DIGEST="${DIGEST%% *}"
# Creating a hard link is atomic and refuses to overwrite a concurrent output.
/bin/ln "$TEMP_ZIP" "$OUTPUT_DIR/" || fail "Archive already exists or cannot be written."
print -r -- "$FINAL_ZIP"
print -- "SHA-256: $DIGEST"

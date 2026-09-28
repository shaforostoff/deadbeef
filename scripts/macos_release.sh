#!/bin/bash
# Build DeaDBeeF.app and package it into a drag-to-install DMG
# (app + /Applications symlink), with optional signing and notarization.
#
# Usage:
#   scripts/macos_release.sh [options]
#
# Options:
#   --codesign IDENTITY     Sign the app bundle (e.g. "Developer ID Application: ...")
#                           with hardened runtime and secure timestamp.
#   --sign IDENTITY         Sign the DMG. Defaults to the --codesign identity.
#   --notarize              Submit the DMG to Apple notary service and staple the ticket.
#   --notary-profile NAME   Keychain profile for notarytool
#                           (created with: xcrun notarytool store-credentials NAME ...).
#   --skip-build            Don't run xcodebuild, package the existing Release build.
#   --output DIR            Where to put the DMG (default: osx/build/Release).
#   -h, --help              Show this help.
#
# Example:
#   scripts/macos_release.sh --codesign "$NOTAPP" --sign "$NOTINST" --notarize --notary-profile EmbraceNG-Notary

set -e

SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRCROOT"

CODESIGN_IDENTITY=""
DMG_SIGN_IDENTITY=""
NOTARIZE=false
NOTARY_PROFILE=""
SKIP_BUILD=false
OUTPUT_DIR="$SRCROOT/osx/build/Release"

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_arg() {
    [[ -n "$2" && "$2" != --* ]] || die "$1 requires an argument"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --codesign)       need_arg "$1" "$2"; CODESIGN_IDENTITY="$2"; shift 2 ;;
        --sign)           need_arg "$1" "$2"; DMG_SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize)       NOTARIZE=true; shift ;;
        --notary-profile) need_arg "$1" "$2"; NOTARY_PROFILE="$2"; shift 2 ;;
        --skip-build)     SKIP_BUILD=true; shift ;;
        --output)         need_arg "$1" "$2"; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage >&2; die "unknown option: $1" ;;
    esac
done

if [[ -z "$DMG_SIGN_IDENTITY" ]]; then
    DMG_SIGN_IDENTITY="$CODESIGN_IDENTITY"
fi

if $NOTARIZE; then
    [[ -n "$CODESIGN_IDENTITY" ]] || die "--notarize requires --codesign"
    [[ -n "$NOTARY_PROFILE" ]] || die "--notarize requires --notary-profile"
fi

check_identity() {
    local identity="$1"
    if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
        echo "Available code signing identities:" >&2
        security find-identity -v -p codesigning >&2
        die "code signing identity not found: $identity
(note: DMGs must be signed with a \"Developer ID Application\" certificate;
 \"Developer ID Installer\" certificates can only sign .pkg files)"
    fi
}

[[ -z "$CODESIGN_IDENTITY" ]] || check_identity "$CODESIGN_IDENTITY"
[[ -z "$DMG_SIGN_IDENTITY" || "$DMG_SIGN_IDENTITY" == "$CODESIGN_IDENTITY" ]] || check_identity "$DMG_SIGN_IDENTITY"

VERSION=$(<"build_data/VERSION")
APP_NAME="DeaDBeeF"
BUILT_APP="$SRCROOT/osx/build/Release/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/deadbeef-$VERSION-macos-universal.dmg"

# Build

if ! $SKIP_BUILD; then
    echo "Building $APP_NAME.app ..."
    xcodebuild -project osx/deadbeef.xcodeproj -target DeaDBeeF -configuration Release
fi

[[ -d "$BUILT_APP" ]] || die "$BUILT_APP not found"

# Stage

WORK_DIR="$(mktemp -d -t deadbeef-release)"
trap 'rm -rf "$WORK_DIR"' EXIT

STAGING="$WORK_DIR/dmg"
APP="$STAGING/$APP_NAME.app"
mkdir -p "$STAGING"

echo "Staging $APP_NAME.app ..."
ditto "$BUILT_APP" "$APP"
ln -s /Applications "$STAGING/Applications"

# Sign the app, inside-out: frameworks, plugins, then the bundle itself

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    echo "Signing $APP_NAME.app with \"$CODESIGN_IDENTITY\" ..."

    # Hardened runtime blocks loading libraries signed by other teams;
    # keep third-party plugins in ~/Library/Application Support/Deadbeef working.
    ENTITLEMENTS="$WORK_DIR/entitlements.plist"
    cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

    sign() {
        codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$@"
    }

    if [[ -d "$APP/Contents/Frameworks" ]]; then
        find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 |
            while IFS= read -r -d '' fw; do sign "$fw"; done
        find "$APP/Contents/Frameworks" -maxdepth 1 -type f -name "*.dylib" -print0 |
            while IFS= read -r -d '' lib; do sign "$lib"; done
    fi

    if [[ -d "$APP/Contents/PlugIns" ]]; then
        find "$APP/Contents/PlugIns" -type f -name "*.dylib" -print0 |
            while IFS= read -r -d '' lib; do sign "$lib"; done
    fi

    sign --entitlements "$ENTITLEMENTS" "$APP"

    echo "Verifying app signature ..."
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

# Create DMG

echo "Creating $DMG_PATH ..."
mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"

if [[ -n "$DMG_SIGN_IDENTITY" ]]; then
    echo "Signing DMG with \"$DMG_SIGN_IDENTITY\" ..."
    codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi

# Notarize

if $NOTARIZE; then
    echo "Submitting DMG for notarization (profile: $NOTARY_PROFILE) ..."
    SUBMIT_LOG="$WORK_DIR/notarize.json"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json | tee "$SUBMIT_LOG"
    echo

    STATUS=$(plutil -extract status raw -o - "$SUBMIT_LOG" 2>/dev/null || true)
    if [[ "$STATUS" != "Accepted" ]]; then
        SUBMISSION_ID=$(plutil -extract id raw -o - "$SUBMIT_LOG" 2>/dev/null || true)
        if [[ -n "$SUBMISSION_ID" ]]; then
            echo "Notarization log:" >&2
            xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        die "notarization failed (status: ${STATUS:-unknown})"
    fi

    echo "Stapling ticket ..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    echo "Gatekeeper assessment ..."
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

echo "Done: $DMG_PATH"

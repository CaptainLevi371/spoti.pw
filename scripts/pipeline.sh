```bash
#!/usr/bin/env bash
#
# Builds the spotifyglass tweak and injects it (plus optional FLEX)
# into a decrypted Spotify IPA.
#
# Usage:
#   scripts/pipeline.sh <decrypted.ipa>
#   scripts/pipeline.sh <decrypted.ipa> -o out.ipa
#   scripts/pipeline.sh <decrypted.ipa> --no-flex
#   scripts/pipeline.sh <decrypted.ipa> --install
#   scripts/pipeline.sh <decrypted.ipa> --name "Spotify"
#   scripts/pipeline.sh <decrypted.ipa> --icon icon.png
#
# Or:
#   make build
#   make install
#
# Requirements:
#   - macOS
#   - Xcode with iPhoneOS SDK
#   - Theos
#   - GNU make
#   - ldid
#   - dpkg-deb
#   - cyan
#
# cyan:
#   uv tool install "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw"
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"

FLEX_DEB="$ROOT/vendor/com.hopeless.autoflex_0.0.1_iphoneos-arm.deb"

# Optional bundle ID override.
BUNDLE_ID="${BUNDLE_ID:-}"

mkdir -p "$ROOT/out"

#
# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
#

IN=""
OUT=""
WITH_FLEX=1
INSTALL=0
NAME=""
ICON=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o)
            OUT="$2"
            shift 2
            ;;

        --name)
            NAME="$2"
            shift 2
            ;;

        --icon)
            ICON="$2"
            shift 2
            ;;

        --no-flex)
            WITH_FLEX=0
            shift
            ;;

        --install)
            INSTALL=1
            shift
            ;;

        -h|--help)
            sed -n '2,35p' "$0"
            exit 0
            ;;

        *)
            IN="$1"
            shift
            ;;
    esac
done

[ -n "$IN" ] || {
    echo "ERROR: no IPA supplied."
    echo "Put a decrypted Spotify IPA in ipa/, or pass one explicitly."
    exit 1
}

[ -f "$IN" ] || {
    echo "ERROR: no such file: $IN"
    exit 1
}

#
# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
#

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: missing $1 -> $2" >&2
        exit 1
    }
}

need gmake "brew install make"
need ldid "brew install ldid"
need dpkg-deb "brew install dpkg"
need cyan "uv tool install 'cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw'"

#
# ---------------------------------------------------------------------------
# Check iPhoneOS SDK
# ---------------------------------------------------------------------------
#

{
    ls -d \
        "$THEOS"/sdks/iPhoneOS*.sdk \
        "$(xcode-select -p 2>/dev/null)"/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk \
        2>/dev/null || true
} |
grep -qE 'iPhoneOS(2[6-9]|[3-9][0-9])\.' || {
    echo "ERROR: no iPhoneOS 26+ SDK found."
    echo "Select Xcode 26+ or put the SDK in:"
    echo "  $THEOS/sdks"
    exit 1
}

#
# ---------------------------------------------------------------------------
# Check icon/Pillow
# ---------------------------------------------------------------------------
#

if [ -n "$ICON" ]; then
    [ -f "$ICON" ] || {
        echo "ERROR: no such icon: $ICON"
        exit 1
    }

    CYAN_DIR="$(dirname "$(readlink -f "$(command -v cyan)")")"

    "$CYAN_DIR/python" -c 'import PIL' >/dev/null 2>&1 || {
        echo "ERROR: cyan does not have Pillow."
        echo
        echo "Install it with:"
        echo "  uv tool install --force --with pillow 'cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw'"
        exit 1
    }
fi

#
# ---------------------------------------------------------------------------
# Find app inside IPA
# ---------------------------------------------------------------------------
#

APP_DIR="$(
    unzip -Z1 "$IN" |
    grep -oE '^Payload/[^/]+\.app/' |
    sort -u |
    head -1
)"

[ -n "$APP_DIR" ] || {
    echo "ERROR: no Payload/*.app found in:"
    echo "  $IN"
    exit 1
}

#
# ---------------------------------------------------------------------------
# Read Spotify version
# ---------------------------------------------------------------------------
#

unzip -p "$IN" "${APP_DIR}Info.plist" > "$ROOT/out/.info.plist"

SPOTIFY_VERSION="$(
    plutil \
        -extract CFBundleShortVersionString raw \
        -o - \
        "$ROOT/out/.info.plist"
)"

rm -f "$ROOT/out/.info.plist"

#
# ---------------------------------------------------------------------------
# Output filename
# ---------------------------------------------------------------------------
#

MOD_VERSION="$(cat "$ROOT/version.txt" 2>/dev/null || true)"
: "${MOD_VERSION:=0.0.0}"

OUT="${OUT:-$ROOT/out/spoti.pw-$MOD_VERSION.ipa}"

echo
echo "=========================================="
echo " spoti.pw build"
echo "=========================================="
echo " mod version:      $MOD_VERSION"
echo " Spotify version:  $SPOTIFY_VERSION"
echo " input:            $IN"
echo " output:           $OUT"
echo "=========================================="
echo

#
# ---------------------------------------------------------------------------
# Initialize injection list
# ---------------------------------------------------------------------------
#
# IMPORTANT:
# This must exist before any FILES+=() calls later in the script.
#

FILES=()

#
# ---------------------------------------------------------------------------
# Extract flag table if necessary
# ---------------------------------------------------------------------------
#

if [ ! -f "$ROOT/tweak/Sources/Shared/Flags/SGFlagList.m" ]; then
    echo "==> extracting the flag table"

    "$ROOT/scripts/extract-flags.py" "$IN"
fi

#
# ---------------------------------------------------------------------------
# Build main tweak
# ---------------------------------------------------------------------------
#

echo "==> building spoti.pw tweak"

export THEOS

#
# Theos normally finds clang through xcrun.
# If only Command Line Tools are available, explicitly provide tools.
#

if ! xcrun -sdk iphoneos --find clang >/dev/null 2>&1; then

    export TARGET_CC=clang
    export TARGET_CXX=clang++
    export TARGET_LD=clang++
    export TARGET_STRIP=strip
    export TARGET_LIPO=lipo
    export TARGET_CODESIGN_ALLOCATE=codesign_allocate
    export TARGET_LIBTOOL=libtool

fi

#
# Theos only builds certain Swift support tools at MAKELEVEL 0.
#

env -u MAKELEVEL \
    gmake -C "$ROOT/tweak" clean package >/dev/null

TWEAK_DEB="$(
    ls -t "$ROOT"/tweak/packages/*.deb |
    head -1
)"

echo "    tweak: $TWEAK_DEB"

#
# ---------------------------------------------------------------------------
# Add main tweak
# ---------------------------------------------------------------------------
#

FILES+=("$TWEAK_DEB")

#
# ---------------------------------------------------------------------------
# Optional FLEX
# ---------------------------------------------------------------------------
#

if [ "$WITH_FLEX" = 1 ]; then

    if [ -f "$FLEX_DEB" ]; then
        echo "==> adding FLEX"
        FILES+=("$FLEX_DEB")
    else
        echo "WARNING: FLEX package not found:"
        echo "  $FLEX_DEB"
        echo "Continuing without FLEX."
    fi

fi

#
# ---------------------------------------------------------------------------
# Build Live Activity extension
# ---------------------------------------------------------------------------
#

EXT_DIR=""

if xcrun --sdk iphoneos --find swiftc >/dev/null 2>&1; then

    echo "==> building Live Activity extension"

    EXT_DIR="$ROOT/out/extension"

    rm -rf "$EXT_DIR"
    mkdir -p "$EXT_DIR"

    unzip -p "$IN" "${APP_DIR}Info.plist" \
        > "$ROOT/out/.info.plist"

    "$ROOT/scripts/build-extension.sh" \
        "$ROOT/out/.info.plist" \
        "$EXT_DIR"

    rm -f "$ROOT/out/.info.plist"

    if [ -d "$EXT_DIR/SpotifyGlassLiveActivity.appex" ]; then
        FILES+=("$EXT_DIR/SpotifyGlassLiveActivity.appex")
    else
        echo "WARNING: Live Activity appex was not produced."
    fi

else

    echo "==> no Swift compiler available"
    echo "    building without Live Activity extension"

fi

#
# ---------------------------------------------------------------------------
# Build App Group shim
# ---------------------------------------------------------------------------
#

echo "==> building App Group shim"

GROUPS_DYLIB="$ROOT/out/SpotifyGlassAppGroups.dylib"

xcrun --sdk iphoneos clang \
    -target arm64-apple-ios16.0 \
    -dynamiclib \
    -fobjc-arc \
    -Os \
    -framework Foundation \
    -framework Security \
    -install_name @rpath/SpotifyGlassAppGroups.dylib \
    -o "$GROUPS_DYLIB" \
    "$ROOT/extension/AppGroups/AppGroups.m"

FILES+=("$GROUPS_DYLIB")

#
# ---------------------------------------------------------------------------
# OPTIONAL ADDITIONAL IPA COMPONENTS
# ---------------------------------------------------------------------------
#
# Add legitimate/non-premium-bypassing dylibs, frameworks, bundles or
# appex files here if your project requires them.
#
# Examples:
#
# EXTRA_DYLIB="$ROOT/vendor/example.dylib"
# [ -f "$EXTRA_DYLIB" ] && FILES+=("$EXTRA_DYLIB")
#
# EXTRA_FRAMEWORK="$ROOT/vendor/Example.framework"
# [ -d "$EXTRA_FRAMEWORK" ] && FILES+=("$EXTRA_FRAMEWORK")
#

#
# ---------------------------------------------------------------------------
# Display injection list
# ---------------------------------------------------------------------------
#

echo
echo "==> injection files"

for FILE in "${FILES[@]}"; do
    echo "    $FILE"
done

echo

#
# ---------------------------------------------------------------------------
# Inject everything with Cyan
# ---------------------------------------------------------------------------
#

echo "==> injecting"

CYAN_ARGS=(
    -i "$IN"
    -o "$OUT"
    -f "${FILES[@]}"
    -l "$ROOT/plist/liquid-glass.plist"
    -w
    -s
    --overwrite
)

if [ -n "$BUNDLE_ID" ]; then
    CYAN_ARGS+=(
        -b "$BUNDLE_ID"
    )
fi

if [ -n "$NAME" ]; then
    CYAN_ARGS+=(
        -n "$NAME"
    )
fi

if [ -n "$ICON" ]; then
    CYAN_ARGS+=(
        -k "$ICON"
    )
fi

cyan "${CYAN_ARGS[@]}"

#
# ---------------------------------------------------------------------------
# Inject App Group shim into Spotify widget
# ---------------------------------------------------------------------------
#

echo "==> checking Spotify widget"

WIDGET_BIN="${APP_DIR}PlugIns/WidgetExtension.appex/WidgetExtension"

if unzip -l "$OUT" "$WIDGET_BIN" >/dev/null 2>&1; then

    echo "==> loading App Group shim into widget"

    PATCH="$(mktemp -d)"

    unzip -q "$OUT" "$WIDGET_BIN" -d "$PATCH"

    "$ROOT/scripts/insert-dylib.py" \
        "$PATCH/$WIDGET_BIN" \
        @rpath/SpotifyGlassAppGroups.dylib

    #
    # Preserve the widget's existing entitlements.
    #

    ldid -e \
        "$PATCH/$WIDGET_BIN" \
        > "$PATCH/ents.plist"

    ldid \
        -S"$PATCH/ents.plist" \
        "$PATCH/$WIDGET_BIN"

    OUT_ABS="$(
        cd "$(dirname "$OUT")" &&
        pwd
    )/$(basename "$OUT")"

    (
        cd "$PATCH"
        zip -q "$OUT_ABS" "$WIDGET_BIN"
    )

    rm -rf "$PATCH"

else

    echo "    no WidgetExtension.appex found"

fi

#
# ---------------------------------------------------------------------------
# Merge Live Activity App Intents metadata
# ---------------------------------------------------------------------------
#

if [ -n "${EXT_DIR:-}" ] &&
   [ -f "$EXT_DIR/app/Metadata.appintents" ]; then

    echo "==> adding Live Activity App Intents metadata"

    "$ROOT/scripts/merge-appintents.py" \
        "$OUT" \
        "$APP_DIR" \
        "$EXT_DIR/app/Metadata.appintents"

fi

#
# ---------------------------------------------------------------------------
# Finished
# ---------------------------------------------------------------------------
#

echo
echo "=========================================="
echo " BUILD COMPLETE"
echo "=========================================="
echo
echo "IPA:"
echo "  $OUT"
echo

#
# ---------------------------------------------------------------------------
# Optional installation
# ---------------------------------------------------------------------------
#

if [ "$INSTALL" = 1 ]; then

    echo "==> handing IPA to install.sh"

    exec "$ROOT/scripts/install.sh" "$OUT"

fi

exit 0
```

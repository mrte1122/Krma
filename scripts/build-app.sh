#!/bin/bash
# Builds a universal (Apple silicon + Intel) Krma.app into ./build.
#   --install    also copy it to ~/Applications
#   --zip        also produce build/Krma.zip for a GitHub release
#   --notarize   with --zip: submit to Apple's notary service and staple the ticket
#                (needs a Developer ID certificate and a stored notarytool profile)
#
# Signing: uses your "Developer ID Application" certificate when one is in the Keychain
# (or KRMA_SIGN_IDENTITY), otherwise falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0; ZIP=0; NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        --notarize) NOTARIZE=1; ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# notarytool profiles are per Apple ID, so Quotacat's works here too: KRMA_NOTARY_PROFILE=quotacat-notary
NOTARY_PROFILE="${KRMA_NOTARY_PROFILE:-krma-notary}"
SIGN_IDENTITY="${KRMA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"

VERSION="${KRMA_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="io.github.mrte1122.Krma"
# Assemble and sign outside the repo: if it lives in an iCloud-synced folder (like ~/Documents),
# File Provider keeps adding extended attributes to the bundle and codesign rejects them.
STAGE="${TMPDIR:-/tmp}/krma-build"
APP="$STAGE/Krma.app"
mkdir -p build

# Build each architecture separately and merge with lipo; separate scratch paths because newer
# SwiftPM otherwise writes both builds to the same .build/out folder.
BINS=()
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --scratch-path ".build/$arch"
    BINS+=("$(swift build -c release --arch "$arch" --scratch-path ".build/$arch" --show-bin-path)/Krma")
done

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Krma"

# App icon: render it if missing, then pack every macOS size into an .icns.
[[ -f Resources/AppIcon.png ]] || swift scripts/make-icon.swift Resources/AppIcon.png
ICONSET="$STAGE/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# CFBundleURLTypes registers krma://, which Reddit's OAuth redirect uses to return to the app.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Krma</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Krma</string>
    <key>CFBundleDisplayName</key><string>Krma</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Tyler Lovelady. MIT License.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}.oauth</string>
            <key>CFBundleURLSchemes</key><array><string>krma</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# sips leaves extended attributes that codesign rejects.
xattr -cr "$APP"
if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    SIGNED_AS="$SIGN_IDENTITY"
else
    if [[ $NOTARIZE -eq 1 ]]; then echo "error: --notarize needs a Developer ID Application certificate" >&2; exit 1; fi
    codesign --force --sign - --timestamp=none "$APP"
    SIGNED_AS="ad-hoc"
fi
codesign --verify --strict "$APP"
echo "Built Krma.app ($(lipo -archs "$APP/Contents/MacOS/Krma"), signed: $SIGNED_AS)"

if [[ $ZIP -eq 1 ]]; then
    rm -f build/Krma.zip
    ditto -c -k --keepParent "$APP" build/Krma.zip
    if [[ $NOTARIZE -eq 1 ]]; then
        echo "Submitting to Apple's notary service (usually 1-5 minutes)…"
        xcrun notarytool submit build/Krma.zip --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        spctl --assess --type execute "$APP" && echo "Gatekeeper accepts the notarized app"
        rm -f build/Krma.zip
        ditto -c -k --keepParent "$APP" build/Krma.zip
    fi
    echo "Packaged build/Krma.zip"
fi

rm -rf build/Krma.app
ditto "$APP" build/Krma.app

if [[ $INSTALL -eq 1 ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Krma.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/Krma.app"
fi

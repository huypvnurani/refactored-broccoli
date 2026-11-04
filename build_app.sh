#!/bin/bash
# Builds MacCharge into a double-clickable .app bundle.
#   ./build_app.sh            → universal binary (Apple Silicon + Intel)
#   ./build_app.sh --native   → faster build for THIS Mac's architecture only
#   ./build_app.sh --zip      → also produce a distributable dist/ zip
# Drop a 1024×1024 logo.png in this folder to use your own artwork for the icon.
set -e
cd "$(dirname "$0")"

ARCH_ARGS=(--arch arm64 --arch x86_64)
MODE="universal"
MAKE_ZIP=0
for a in "$@"; do
  case "$a" in
    --native)    ARCH_ARGS=(); MODE="native" ;;
    --zip)       MAKE_ZIP=1 ;;
  esac
done

echo "▸ Generating app icon…"
python3 make_icon.py || echo "  (icon generation skipped)"

echo "▸ Building release binary ($MODE)…"
swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/MacCharge"
HELPER="$BIN_DIR/MacChargeFanHelper"

APP="MacCharge.app"
echo "▸ Assembling \"$APP\"…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacCharge"
# Fan control writes the SMC, which only root may do: this auxiliary binary is
# what the app installs setuid-root (behind an admin prompt) on first use.
cp "$HELPER" "$APP/Contents/MacOS/maccharge-fanhelper"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacCharge</string>
    <key>CFBundleDisplayName</key><string>MacCharge</string>
    <key>CFBundleIdentifier</key><string>com.urani.maccharge</string>
    <key>CFBundleVersion</key><string>1.2.0</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>CFBundleExecutable</key><string>MacCharge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSDesktopFolderUsageDescription</key><string>FolderTree measures how much space the folders on your Desktop use.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>FolderTree measures how much space the folders in Documents use.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>FolderTree measures how much space the folders in Downloads use.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>FolderTree measures how much space folders on removable drives use.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>FolderTree measures how much space folders on network drives use.</string>
</dict>
</plist>
PLIST

# --- Spotlight keywords -------------------------------------------------
# Writes kMDItemKeywords + a Finder comment onto the bundle so Spotlight finds
# the app by terms other than its name. Edit the list below as you like.
SPOTLIGHT_KEYWORDS="MacCharge, Mac Charge, power, charge, wat, watt, battery, batt, pin, sac, sạc, sac pin, pin macbook, charger, adapter, battery health, do pin"
python3 - "$APP" "$SPOTLIGHT_KEYWORDS" <<'PYKW'
import plistlib, subprocess, sys
app, raw = sys.argv[1], sys.argv[2]
words = [w.strip() for w in raw.split(",") if w.strip()]
def setx(name, value):
    data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY).hex()
    subprocess.run(["xattr", "-w", "-x", "com.apple.metadata:" + name, data, app], check=True)
setx("kMDItemKeywords", words)
setx("kMDItemFinderComment", " ".join(words))
PYKW
mdimport "$APP" 2>/dev/null || true
echo "✓ Spotlight keywords: $SPOTLIGHT_KEYWORDS"

# --- Code signing -------------------------------------------------------
# Signs with your "Developer ID Application" certificate when one is in the
# keychain, which is what lets other Macs open the app without a warning.
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./build_app.sh   ← pick one
#   SIGN_ID=- ./build_app.sh                                          ← force ad-hoc
# Signing happens AFTER the Spotlight xattrs so they cannot invalidate the seal.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning \
             | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
  echo "▸ Signing: $SIGN_ID"
  # Inner binary first, then the bundle (--deep is deprecated by Apple).
  codesign --force --timestamp --options runtime \
           --sign "$SIGN_ID" "$APP/Contents/MacOS/maccharge-fanhelper"
  codesign --force --timestamp --options runtime \
           --sign "$SIGN_ID" "$APP/Contents/MacOS/MacCharge"
  codesign --force --timestamp --options runtime \
           --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "✓ Signed with Developer ID (hardened runtime + secure timestamp)"
else
  echo "▸ No Developer ID identity — ad-hoc signing (this Mac only)."
  codesign --force --sign - "$APP/Contents/MacOS/maccharge-fanhelper" 2>/dev/null || true
  codesign --force --sign - "$APP/Contents/MacOS/MacCharge" 2>/dev/null || true
  codesign --force --sign - "$APP" 2>/dev/null || true
fi
touch "$APP"

echo "✓ Built \"$APP\""
echo "  Architectures: $(lipo -archs "$APP/Contents/MacOS/MacCharge" 2>/dev/null)"

if [ "$MAKE_ZIP" = "1" ]; then
  mkdir -p dist
  ZIP="dist/MacCharge-1.2.0-macOS12.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ Zipped → $ZIP  ($(du -h "$ZIP" | cut -f1))"
fi

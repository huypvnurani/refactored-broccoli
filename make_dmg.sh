#!/bin/bash
# Packages MacCharge into a drag-to-Applications .dmg.
#
# If a "Developer ID Application" certificate is in the keychain the app is
# signed with it, and if a notarytool keychain profile exists the app and the
# dmg are also notarized + stapled — recipients then just drag and run.
# One-time setup of that profile (run it yourself, it asks for credentials):
#   xcrun notarytool store-credentials maccharge-notary \
#     --apple-id you@example.com --team-id 7797UMZFQR --password <app-specific-password>
# Override the profile name with NOTARY_PROFILE=... if you use another one.
set -e
cd "$(dirname "$0")"

APP="MacCharge.app"
VERSION="1.3.0"
NOTARY_PROFILE="${NOTARY_PROFILE:-maccharge-notary}"

echo "▸ Building universal app first…"
./build_app.sh            # default = universal (Intel + Apple Silicon)

# What did build_app.sh actually sign with?
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)"
NOTARIZED=0

if [ -n "$SIGNER" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "▸ Notarizing the app (profile: $NOTARY_PROFILE)…"
  mkdir -p dist
  NZIP="dist/MacCharge-$VERSION-notarize.zip"
  rm -f "$NZIP"
  ditto -c -k --keepParent "$APP" "$NZIP"
  xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$NZIP"
  NOTARIZED=1
  echo "✓ App notarized and stapled"
elif [ -n "$SIGNER" ]; then
  echo "▸ Signed, but no notarytool profile \"$NOTARY_PROFILE\" — skipping notarization."
else
  echo "▸ Ad-hoc signed only — skipping notarization."
fi

STAGING="$(mktemp -d)"
ditto "$APP" "$STAGING/$APP"   # ditto preserves the Spotlight-keyword xattrs
ln -s /Applications "$STAGING/Applications"

# Short install note for recipients.
if [ "$NOTARIZED" = "1" ]; then
cat > "$STAGING/README - How to open.txt" <<'TXT'
INSTALLING MacCharge
=====================
1. Drag "MacCharge" into the Applications folder (the icon next to it).
2. Open it from Launchpad or Applications. That is all — the app is signed and
   notarized by Apple, so no security warning appears.
TXT
else
cat > "$STAGING/README - How to open.txt" <<'TXT'
INSTALLING MacCharge
=====================
1. Drag "MacCharge" into the Applications folder (the icon next to it).
2. On first launch macOS may say the developer cannot be verified:
   . Open  System Settings > Privacy & Security
   . Scroll down and click "Open Anyway" on the MacCharge line.
   Or run this single command in Terminal:
       xattr -dr com.apple.quarantine "/Applications/MacCharge.app"
3. That is it. It opens normally from then on.
TXT
fi

mkdir -p dist
DMG="dist/MacCharge-$VERSION.dmg"
rm -f "$DMG"
echo "▸ Creating $DMG…"
hdiutil create -volname "MacCharge" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# Sign + notarize the disk image itself so the download is trusted too.
if [ -n "$SIGNER" ]; then
  echo "▸ Signing the dmg…"
  codesign --force --timestamp --sign "$SIGNER" "$DMG"
fi
if [ "$NOTARIZED" = "1" ]; then
  echo "▸ Notarizing the dmg…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || true
fi

echo "✓ Done → $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1))"

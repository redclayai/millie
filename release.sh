#!/usr/bin/env bash
# Millie release pipeline: take the locally-built ~/Downloads/Millie.app and turn
# it into a distributable, notarized, auto-updatable product.
#
#   build (ninja) → package_mori.sh → release.sh
#
# release.sh does, in order:
#   1. Stage a copy, set the product bundle id + Millie version.
#   2. (If vendored) embed Sparkle.framework + write its Info.plist keys.
#   3. Sign every nested binary inside-out with Developer ID + hardened runtime.
#   4. Notarize + staple the .app.
#   5. Build a DMG, sign + notarize + staple it.
#   6. (If Sparkle present) sign the DMG with the EdDSA key and update appcast.xml.
#
# One-time setup the user must do (Apple side):
#   • Create a "Developer ID Application" cert in Xcode → Settings → Accounts →
#     Manage Certificates → ＋ → Developer ID Application.
#   • Store notary creds once:
#       xcrun notarytool store-credentials millie-notary \
#         --apple-id <you@apple-id> --team-id 24YK5W5KY4 --password <app-specific-pw>
set -euo pipefail

# ---- Config (override via env) ----------------------------------------------
# Auto-detect the Developer ID Application identity (certs are named after the
# organization). Override with MILLIE_DEV_ID if you have more than one.
DEV_ID="${MILLIE_DEV_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
# Team ID lives in the identity's trailing (XXXXXXXXXX); derive it from DEV_ID.
TEAM_ID="${MILLIE_TEAM_ID:-$(printf '%s' "$DEV_ID" | sed -n 's/.*(\([A-Z0-9]*\)).*/\1/p')}"
BUNDLE_ID="${MILLIE_BUNDLE_ID:-app.millie}"
NOTARY_PROFILE="${MILLIE_NOTARY_PROFILE:-millie-notary}"
MILLIE_VERSION="${MILLIE_VERSION:-2.1}"
# Monotonic build number; pass MILLIE_BUILD to pin it for reproducibility.
BUILD_NUMBER="${MILLIE_BUILD:-$(date +%Y%m%d%H%M)}"
# Where the appcast tells clients to look + where the public key lives.
FEED_URL="${MILLIE_FEED_URL:-https://github.com/redclayai/millie/releases/latest/download/appcast.xml}"
SU_PUBLIC_KEY="${MILLIE_SU_PUBKEY:-nAEqm11bUO+gwO37HvV+FKvFuZ1x6bjW74ZFbxU7HGc=}"  # Sparkle EdDSA public key (private key in login keychain)
DL_BASE_URL="${MILLIE_DL_BASE_URL:-https://github.com/redclayai/millie/releases/download}"
REPO="${MILLIE_REPO:-redclayai/millie}"          # gh repo for --publish

ROOT="$HOME/mori-browser-build"
SRC_APP="${MILLIE_APP:-$HOME/mori-browser-build/Millie.app}"  # package_mori.sh output (build tree, not TCC-blocked ~/Downloads)
SPARKLE_FW="$ROOT/millie/Sparkle.framework"     # vendored by the Sparkle step
ENT_DIR="$ROOT/entitlements"
OUT="$ROOT/dist"
STAGE="$OUT/Millie.app"
DMG="$OUT/Millie-$MILLIE_VERSION.dmg"
APPCAST="$OUT/appcast.xml"

NOTARIZE=1; PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --publish)     PUBLISH=1 ;;
    *) echo "unknown flag: $arg (use --no-notarize / --publish)"; exit 2 ;;
  esac
done

# ---- Identity check ----------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "‼️  No 'Developer ID Application' certificate found in the keychain."
  echo "   Create one: Xcode → Settings → Accounts → Manage Certificates → ＋ → Developer ID Application."
  echo "   (You currently only have an 'Apple Development' cert, which can't be notarized.)"
  echo "   Re-run once it's installed. Aborting before signing."
  exit 1
fi

[[ -d "$SRC_APP" ]] || { echo "Missing $SRC_APP — run package_mori.sh first."; exit 1; }

echo "==> Staging $SRC_APP → $STAGE"
rm -rf "$OUT"; mkdir -p "$OUT"
/usr/bin/ditto "$SRC_APP" "$STAGE"

PLIST="$STAGE/Contents/Info.plist"

echo "==> Branding identity: $BUNDLE_ID  version $MILLIE_VERSION ($BUILD_NUMBER)"
plutil -replace CFBundleIdentifier        -string "$BUNDLE_ID"      "$PLIST"
plutil -replace CFBundleShortVersionString -string "$MILLIE_VERSION" "$PLIST"
plutil -replace CFBundleVersion           -string "$BUILD_NUMBER"   "$PLIST"

# ---- Sparkle embed (if vendored) --------------------------------------------
if [[ -d "$SPARKLE_FW" ]]; then
  echo "==> Embedding Sparkle.framework + appcast keys"
  /usr/bin/ditto "$SPARKLE_FW" "$STAGE/Contents/Frameworks/Sparkle.framework"
  plutil -replace SUFeedURL            -string "$FEED_URL"   "$PLIST"
  plutil -replace SUEnableAutomaticChecks -bool true         "$PLIST"
  plutil -replace SUScheduledCheckInterval -integer 86400    "$PLIST"
  [[ -n "$SU_PUBLIC_KEY" ]] && plutil -replace SUPublicEDKey -string "$SU_PUBLIC_KEY" "$PLIST"
else
  echo "==> (Sparkle.framework not vendored yet — skipping auto-update embed)"
fi

# ---- Inside-out code signing -------------------------------------------------
SIGN=(codesign --force --timestamp --options runtime --sign "$DEV_ID")
FW="$STAGE/Contents/Frameworks/Chromium Framework.framework"
VERDIR="$(/bin/ls -d "$FW"/Versions/* | grep -v Current | head -1)"

echo "==> Signing nested libraries"
find "$VERDIR/Libraries" -type f -name "*.dylib" 2>/dev/null | while read -r f; do
  "${SIGN[@]}" "$f"
done

echo "==> Signing loose helper executables"
for exe in chrome_crashpad_handler app_mode_loader web_app_shortcut_copier; do
  [[ -f "$VERDIR/Helpers/$exe" ]] && "${SIGN[@]}" "$VERDIR/Helpers/$exe"
done

echo "==> Signing helper apps (with entitlements)"
ent_for() {  # pick entitlements by helper name
  case "$1" in
    *Renderer*) echo "$ENT_DIR/helper-renderer-entitlements.plist" ;;
    *GPU*)      echo "$ENT_DIR/helper-gpu-entitlements.plist" ;;
    *Plugin*|"Chromium Helper.app") echo "$ENT_DIR/helper-plugin-entitlements.plist" ;;
    *)          echo "" ;;   # Alerts etc.: hardened runtime, no extra entitlements
  esac
}
find "$VERDIR/Helpers" -maxdepth 1 -name "*.app" | while read -r helper; do
  ent="$(ent_for "$(basename "$helper")")"
  if [[ -n "$ent" ]]; then
    "${SIGN[@]}" --entitlements "$ent" "$helper"
  else
    "${SIGN[@]}" "$helper"
  fi
done

if [[ -d "$STAGE/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "==> Signing Sparkle (XPC services, Autoupdate, framework)"
  SPK="$STAGE/Contents/Frameworks/Sparkle.framework"
  find "$SPK/Versions" \( -name "*.xpc" -o -name "Autoupdate" -o -name "Updater.app" \) -maxdepth 3 2>/dev/null | while read -r item; do
    "${SIGN[@]}" "$item"
  done
  "${SIGN[@]}" "$SPK"
fi

echo "==> Signing Chromium Framework"
"${SIGN[@]}" "$FW"

echo "==> Signing outer app"
"${SIGN[@]}" --entitlements "$ENT_DIR/app-entitlements.plist" "$STAGE"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$STAGE"

# ---- Notarize + staple the app ----------------------------------------------
if [[ $NOTARIZE -eq 1 ]]; then
  echo "==> Notarizing app (this calls Apple; may take a few minutes)"
  ZIP="$OUT/Millie-notarize.zip"
  /usr/bin/ditto -c -k --keepParent "$STAGE" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE"
  rm -f "$ZIP"
fi

# ---- Build DMG ---------------------------------------------------------------
echo "==> Building DMG → $DMG"
DMG_SRC="$OUT/dmgroot"; rm -rf "$DMG_SRC"; mkdir -p "$DMG_SRC"
/usr/bin/ditto "$STAGE" "$DMG_SRC/Millie.app"
ln -s /Applications "$DMG_SRC/Applications"
rm -f "$DMG"
hdiutil create -volname "Millie" -srcfolder "$DMG_SRC" -ov -format UDZO "$DMG"
rm -rf "$DMG_SRC"
"${SIGN[@]}" "$DMG"

if [[ $NOTARIZE -eq 1 ]]; then
  echo "==> Notarizing + stapling DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# ---- Sparkle appcast ---------------------------------------------------------
SIGN_UPDATE="$ROOT/millie/bin/sign_update"
if [[ -x "$SIGN_UPDATE" ]]; then
  echo "==> Signing update + writing appcast"
  # sign_update prints both attrs: sparkle:edSignature="…" length="…"
  SIG_LINE="$("$SIGN_UPDATE" "$DMG")"
  PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Millie</title>
    <item>
      <title>Millie $MILLIE_VERSION</title>
      <description><![CDATA[${MILLIE_NOTES_HTML:-Millie $MILLIE_VERSION update.}]]></description>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$MILLIE_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure url="$DL_BASE_URL/v$MILLIE_VERSION/$(basename "$DMG")"
                 type="application/octet-stream"
                 $SIG_LINE />
    </item>
  </channel>
</rss>
XML
  echo "    appcast → $APPCAST"
else
  echo "==> (Sparkle sign_update not present — skipping appcast; add it in the Sparkle step)"
fi

echo ""
echo "✅ Done."
echo "   App:     $STAGE"
echo "   DMG:     $DMG"
[[ -f "$APPCAST" ]] && echo "   Appcast: $APPCAST"

# ---- Publish to GitHub Releases (gh) -----------------------------------------
if [[ $PUBLISH -eq 1 ]]; then
  TAG="v$MILLIE_VERSION"
  NOTES="${MILLIE_NOTES:-Millie $MILLIE_VERSION — Apple Silicon, macOS 12+. Signed & notarized by Red Clay AI, Inc. Auto-updates via Sparkle.}"
  ASSETS=( "$DMG" )
  [[ -f "$APPCAST" ]] && ASSETS+=( "$APPCAST" )
  echo "==> Publishing $TAG to github.com/$REPO"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    # Re-running the same version: replace the assets in place.
    gh release upload "$TAG" --repo "$REPO" --clobber "${ASSETS[@]}"
  else
    gh release create "$TAG" --repo "$REPO" --target main \
      --title "Millie $MILLIE_VERSION" --notes "$NOTES" "${ASSETS[@]}"
  fi
  echo "   Published → https://github.com/$REPO/releases/tag/$TAG"
else
  echo ""
  echo "   Not published. Re-run with --publish to push the DMG + appcast to"
  echo "   github.com/$REPO, or upload manually to your release host."
fi

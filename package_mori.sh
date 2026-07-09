#!/usr/bin/env bash
# Package the freshly-built Chromium.app as the branded, asset-complete "Millie"
# browser. Output goes to the build tree (NOT ~/Downloads) — macOS TCC blocks
# the shell from writing to ~/Downloads, which silently left stale builds.
# Override the location with MILLIE_APP. Re-runnable after each `ninja chrome`.
# (Product was renamed Mori -> Millie; internal identifiers/asset names that the
#  Swift code keys on — MoriGlyphs/, the "mori" logo asset — intentionally stay.)
set -euo pipefail

SRC_APP="/Users/dannybaute/mori-browser-build/build/src/out/Default/Chromium.app"
OVERLAY="/Users/dannybaute/mori-browser/ungoogled-chromium-macos/build/src/chrome/browser/ui/mori"
APP="${MILLIE_APP:-$HOME/mori-browser-build/Millie.app}"

echo "==> ditto Chromium.app -> $APP"
rm -rf "$APP"
/usr/bin/ditto "$SRC_APP" "$APP"

RES="$APP/Contents/Resources"

echo "==> wiring overlay assets (Bundle.main = outer app Resources)"
# Asset catalog (170 named icons incl. the "mori" logo) replaces Chromium's.
/usr/bin/ditto "$OVERLAY/Assets.car"   "$RES/Assets.car"
# Loose template SVG glyphs: code loads Bundle.main/MoriGlyphs/<name>.svg
# (the runtime path is "MoriGlyphs" — an internal name, left unchanged).
/usr/bin/ditto "$OVERLAY/glyphs/"      "$RES/MoriGlyphs/"
# App icon (CFBundleIconFile=app.icns).
/usr/bin/ditto "$OVERLAY/AppIcon.icns" "$RES/app.icns"
# Bundled Google Sans (OFL) faces — FontRegistry registers Resources/Fonts/*.ttf
# at launch so Typography.ui() resolves to "Google Sans".
FONTS_SRC="/Users/dannybaute/mori-browser-build/millie/fonts"
if [ -d "$FONTS_SRC" ]; then
  /usr/bin/ditto "$FONTS_SRC" "$RES/Fonts"
  echo "    bundled $(ls "$RES/Fonts"/*.ttf 2>/dev/null | wc -l | tr -d ' ') Google Sans faces"
fi

# Offline phishing/malware blocklist — ThreatStore loads Bundle.main/threatlist.bin.
THREATLIST="/Users/dannybaute/mori-browser-build/millie/overlay/threatlist.bin"
if [ -f "$THREATLIST" ]; then
  /usr/bin/ditto "$THREATLIST" "$RES/threatlist.bin"
  echo "    bundled threatlist.bin ($(du -h "$THREATLIST" | cut -f1))"
fi

# Bundled Widevine CDM (arm64), shipped as an opaque zip so notarization does
# not scan the non-hardened Google-signed dylib. On first launch the browser
# extracts it into <user-data>/WidevineCdm (widevine_cdm_component_installer.cc
# MaybeSeedBundledWidevineCdm), enabling premium DRM (Netflix, DirecTV) offline.
WIDEVINE_ZIP="/Users/dannybaute/mori-browser-build/millie/widevine/WidevineCdm.zip"
if [ -f "$WIDEVINE_ZIP" ]; then
  /usr/bin/ditto "$WIDEVINE_ZIP" "$RES/WidevineCdm.zip"
  echo "    bundled WidevineCdm.zip ($(du -h "$WIDEVINE_ZIP" | cut -f1))"
fi

echo "==> branding name -> Millie"
plutil -replace CFBundleDisplayName -string 'Millie' "$APP/Contents/Info.plist"
plutil -replace CFBundleName        -string 'Millie' "$APP/Contents/Info.plist"
# Drop CFBundleIconName: modern macOS prefers the asset-catalog icon it names
# (the old "AppIcon" baked into Assets.car) over our Resources/app.icns. Removing
# it makes the new Millie app.icns the icon Finder/Dock actually shows.
plutil -remove CFBundleIconName "$APP/Contents/Info.plist" 2>/dev/null || true
if [ -f "$RES/en.lproj/InfoPlist.strings" ]; then
  plutil -replace CFBundleDisplayName -string 'Millie' "$RES/en.lproj/InfoPlist.strings" 2>/dev/null || true
fi

echo "==> rename main executable -> Millie (Process name in Activity Monitor / crash reports)"
# Only the outer launcher is renamed. Helpers + bundle id stay org.chromium.Chromium
# (renaming helpers needs a build-config change; changing the bundle id would reset
# camera/mic/location permissions). macOS launches Contents/MacOS/<CFBundleExecutable>.
if [ -f "$APP/Contents/MacOS/Chromium" ]; then
  mv "$APP/Contents/MacOS/Chromium" "$APP/Contents/MacOS/Millie"
  plutil -replace CFBundleExecutable -string 'Millie' "$APP/Contents/Info.plist"
fi

echo "==> embed Sparkle.framework (Swift links it; release.sh re-signs for distribution)"
# The mori_ui_swift target links Sparkle, so the framework must be in the bundle
# or the app won't launch. release.sh overwrites + Developer-ID-signs it and adds
# the appcast feed/key; here it just rides along for local dev.
SPARKLE_FW="/Users/dannybaute/mori-browser-build/millie/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  /usr/bin/ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
fi

echo "==> ad-hoc re-sign (seal changed)"
xattr -cs "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "SIGNED_OK"

touch "$APP" || true
echo "==> done: $APP"

#!/usr/bin/env bash
# Re-apply ALL Millie modifications onto a freshly-prepped ungoogled-chromium
# source tree (build/src), after ungoogled patches + domain substitution and
# BEFORE `gn gen`. Idempotent. Exit 3 signals Chromium API drift (manual port).
set -euo pipefail

ROOT="/Users/dannybaute/mori-browser-build"
SRC="$ROOT/build/src"
MILLIE="$ROOT/millie"

if [ ! -d "$SRC" ]; then echo "apply_millie: $SRC missing"; exit 1; fi

echo "==> apply_millie: copying Mori/Millie overlay (incl. thirdparty/Sparkle.framework) into chrome/browser/ui/mori"
mkdir -p "$SRC/chrome/browser/ui/mori"
/usr/bin/ditto "$MILLIE/overlay" "$SRC/chrome/browser/ui/mori"

echo "==> apply_millie: applying chromium-tree.patch (18 build/UI files)"
cd "$SRC"
if git apply --check --reverse "$MILLIE/chromium-tree.patch" 2>/dev/null; then
  echo "    already applied — skipping."
elif git apply "$MILLIE/chromium-tree.patch" 2>/dev/null; then
  echo "    applied (git apply)."
elif git apply --3way "$MILLIE/chromium-tree.patch" 2>/dev/null; then
  echo "    applied (git apply --3way)."
elif patch -p1 --forward --fuzz=3 < "$MILLIE/chromium-tree.patch" >/dev/null 2>&1; then
  echo "    applied (patch --fuzz=3; context drifted slightly — review)."
else
  echo "!!! apply_millie: chromium-tree.patch did NOT apply — Chromium API drift."
  echo "!!! One of the 18 build/UI files changed upstream; re-port the patch for this version."
  exit 3
fi
echo "==> apply_millie: done."

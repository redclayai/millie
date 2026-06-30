#!/usr/bin/env bash
# Keep Millie's Chromium current with upstream ungoogled-chromium-macos.
#   update_millie.sh           -> check only; notify if a newer tag exists
#   update_millie.sh --build   -> if newer, checkout + rebuild + repackage + record
#
# Same-milestone updates (e.g. 149.0.7827.155 -> 149.0.7827.199) usually apply &
# build cleanly. A major Chromium bump (149 -> 150) will likely fail to build on
# API drift; that needs manual re-porting of the overlay/patches (build is gated
# so the existing Millie.app is left untouched on failure).
set -uo pipefail

ROOT="/Users/dannybaute/mori-browser-build"
MILLIE="$ROOT/millie"
LOG="$MILLIE/update.log"

notify(){ /usr/bin/osascript -e "display notification \"$1\" with title \"Millie Updater\"" >/dev/null 2>&1 || true; }
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

cd "$ROOT" || exit 1
log "Checking upstream for new Chromium tags..."
git fetch --tags --quiet 2>>"$LOG" || log "warning: git fetch failed (offline?)"

CURRENT="$(cat "$MILLIE/current-tag.txt" 2>/dev/null || echo unknown)"
LATEST="$(git tag | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"

log "current=$CURRENT  latest=$LATEST"

if [ -z "$LATEST" ] || [ "$CURRENT" = "$LATEST" ]; then
  log "Millie is up to date ($CURRENT)."
  exit 0
fi

notify "Chromium $LATEST is available (you have $CURRENT)."
log "Update available: $CURRENT -> $LATEST"

if [ "${1:-}" != "--build" ]; then
  log "Run: $MILLIE/update_millie.sh --build   to build & install it."
  exit 0
fi

log "Checking out $LATEST ..."
if ! git checkout --recurse-submodules "$LATEST" >>"$LOG" 2>&1; then
  log "ERROR: git checkout $LATEST failed (local changes?). Aborting; Millie.app untouched."
  notify "Millie update failed: could not checkout $LATEST."
  exit 1
fi

log "Building Millie for $LATEST (multi-hour) ..."
if "$MILLIE/build_millie.sh" >>"$LOG" 2>&1; then
  echo "$LATEST" > "$MILLIE/current-tag.txt"
  log "SUCCESS: Millie updated to $LATEST."
  notify "Millie updated to Chromium $LATEST."
else
  rc=$?
  log "BUILD FAILED (rc=$rc) for $LATEST — likely Chromium API drift; needs manual re-port."
  log "The previous Millie.app is unchanged. Repo is left on tag $LATEST for porting."
  notify "Millie auto-build for $LATEST failed (API drift). Manual port needed."
  exit "$rc"
fi

#!/usr/bin/env bash
# Post-build smoke test for the packaged Millie.app in the build tree.
# Launches detached, exercises the basics, and greps the unified log for the
# health signals we rely on. Exit 0 = PASS, non-zero = FAIL (with reasons).
# Kills any running Millie first (pkill -9 Millie — pattern must NOT be
# 'Millie.app'; the main process argv[0] is plain "Millie").
set -uo pipefail

APP="${MILLIE_APP:-$HOME/mori-browser-build/Millie.app}"
BIN="$APP/Contents/MacOS/Millie"
FAILS=()

[ -x "$BIN" ] || { echo "FAIL: $BIN missing"; exit 1; }

pkill -9 Millie 2>/dev/null; sleep 1

# Detached launch (a plain spawn holds the pipe and hangs harness timeouts).
# Capture the app's stderr to a file so health-signal checks read it directly
# (immediate) instead of the unified log (unpredictable ingestion lag).
RUNLOG="$(mktemp -t millie_smoke)"
/usr/bin/python3 - "$BIN" "https://example.com" "$RUNLOG" <<'EOF'
import os, sys
b, url, logf = sys.argv[1], sys.argv[2], sys.argv[3]
if os.fork() == 0:
    os.setsid()
    devnull = os.open("/dev/null", os.O_RDONLY)
    out = os.open(logf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(devnull, 0); os.dup2(out, 1); os.dup2(out, 2)
    os.execv(b, [b, url])
EOF

# 1. Process comes up and stays up.
for _ in $(seq 1 15); do pgrep -x Millie >/dev/null && break; sleep 1; done
pgrep -x Millie >/dev/null || FAILS+=("browser process did not start")
sleep 8
pgrep -x Millie >/dev/null || FAILS+=("browser process died within 8s")

# 2. Renderer + network service helpers exist (page actually loading).
pgrep -f 'Chromium Helper \((Aperitif )?Renderer\)' >/dev/null || FAILS+=("no renderer process")
pgrep -f 'network.mojom.NetworkService' >/dev/null || FAILS+=("no network service")

# 3. Health signals from the app's stderr (Millie-specific subsystems). Read the
# captured RUNLOG directly — NSLog writes there immediately, so this is not
# subject to unified-log ingestion lag. Poll briefly for the app to reach it.
adblock_ok=0
for _ in $(seq 1 10); do
  if grep -q 'MILLIE_ADBLOCK loaded' "$RUNLOG" 2>/dev/null; then adblock_ok=1; break; fi
  sleep 1
done
[ "$adblock_ok" = 1 ] || FAILS+=("adblock list did not load")

# 4. Bundle resources that must ship.
[ -f "$APP/Contents/Resources/adhosts.bin" ]    || FAILS+=("adhosts.bin missing from bundle")
[ -f "$APP/Contents/Resources/threatlist.bin" ] || FAILS+=("threatlist.bin missing from bundle")

# 5. Code signature validates.
codesign --verify --deep --strict "$APP" 2>/dev/null || FAILS+=("codesign verify failed")

pkill -9 Millie 2>/dev/null
rm -f "$RUNLOG"

if [ ${#FAILS[@]} -gt 0 ]; then
  echo "SMOKE TEST FAIL:"
  printf ' - %s\n' "${FAILS[@]}"
  exit 1
fi
echo "SMOKE TEST PASS"

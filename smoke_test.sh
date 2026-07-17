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
/usr/bin/python3 - "$BIN" "https://example.com" <<'EOF'
import os, sys
b, url = sys.argv[1], sys.argv[2]
if os.fork() == 0:
    os.setsid()
    fd = os.open("/dev/null", os.O_RDWR)
    os.dup2(fd, 0); os.dup2(fd, 1); os.dup2(fd, 2)
    os.execv(b, [b, url])
EOF

# 1. Process comes up and stays up.
for _ in $(seq 1 15); do pgrep -x Millie >/dev/null && break; sleep 1; done
pgrep -x Millie >/dev/null || FAILS+=("browser process did not start")
sleep 8
pgrep -x Millie >/dev/null || FAILS+=("browser process died within 8s")

# 2. Renderer + network service helpers exist (page actually loading).
pgrep -f 'Chromium Helper \(Renderer\)' >/dev/null || FAILS+=("no renderer process")
pgrep -f 'network.mojom.NetworkService' >/dev/null || FAILS+=("no network service")

# 3. Health signals in the unified log (Millie-specific subsystems).
LOG=$(/usr/bin/log show --predicate 'process=="Millie"' --last 2m 2>/dev/null)
echo "$LOG" | grep -q 'MILLIE_ADBLOCK loaded' || FAILS+=("adblock list did not load")

# 4. Bundle resources that must ship.
[ -f "$APP/Contents/Resources/adhosts.bin" ]    || FAILS+=("adhosts.bin missing from bundle")
[ -f "$APP/Contents/Resources/threatlist.bin" ] || FAILS+=("threatlist.bin missing from bundle")

# 5. Code signature validates.
codesign --verify --deep --strict "$APP" 2>/dev/null || FAILS+=("codesign verify failed")

pkill -9 Millie 2>/dev/null

if [ ${#FAILS[@]} -gt 0 ]; then
  echo "SMOKE TEST FAIL:"
  printf ' - %s\n' "${FAILS[@]}"
  exit 1
fi
echo "SMOKE TEST PASS"

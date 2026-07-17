#!/usr/bin/env bash
# Compares Millie's pinned ungoogled-chromium version against the newest
# upstream release. Exit 0 + "UP_TO_DATE" when current, exit 0 + "NEW <tag>"
# when an update exists (the daily update pipeline keys off this output).
set -euo pipefail

PINNED_FILE="$(cd "$(dirname "$0")" && pwd)/CHROMIUM_VERSION"
PINNED="$(cat "$PINNED_FILE")"

LATEST=$(curl -fsSL --max-time 30 \
  "https://api.github.com/repos/ungoogled-software/ungoogled-chromium-macos/releases/latest" \
  | /usr/bin/python3 -c 'import sys, json; print(json.load(sys.stdin)["tag_name"])')

if [ -z "$LATEST" ]; then
  echo "ERROR could not resolve upstream latest release" >&2
  exit 1
fi

if [ "$LATEST" == "$PINNED" ]; then
  echo "UP_TO_DATE $PINNED"
else
  echo "NEW $LATEST (current: $PINNED)"
fi

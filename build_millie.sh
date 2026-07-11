#!/usr/bin/env bash
# Build Millie from the currently checked-out ungoogled-chromium-macos tag.
# Wraps upstream build.sh: injects the Millie overlay+patches before `gn gen`,
# swaps the (dev-cert) signing step for ad-hoc, then packages ~/Downloads/Millie.app.
#
# Usage: build_millie.sh [arm64|x86_64] [-d]
#   -d  reuse the existing build/src checkout (skip re-clone) — passed to build.sh
# Multi-hour: clones/preps the Chromium source if needed, then compiles.
set -euo pipefail

ROOT="/Users/dannybaute/mori-browser-build"
MILLIE="$ROOT/millie"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# venv python 3.13 (depot_tools needs >=3.10), gnu-sed, coreutils (greadlink), ninja
export PATH="$ROOT/buildpy/bin:/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$PATH"

cd "$ROOT"

# Build an injected copy of upstream build.sh:
#  1. run apply_millie.sh immediately before `gn gen`
#  2. replace the dev-cert sign_and_package_app.sh call with ad-hoc codesign
awk -v inj="\"$MILLIE/apply_millie.sh\"" '
  /\.\/out\/Default\/gn gen out\/Default/ && !g { print inj; g=1 }
  /sign_and_package_app\.sh/ {
    print "codesign --force --deep --sign - \"$_src_dir/out/Default/Chromium.app\" || true"; next }
  { print }
' build.sh > "$ROOT/.build_injected.sh"

echo "==> build_millie: compiling (this can take several hours)"
# Run from $ROOT so build.sh's _root_dir (dirname of $0) resolves to the outer
# repo, where retrieve_and_unpack_resource.sh / ungoogled/ / patches/ live.
bash "$ROOT/.build_injected.sh" "$@"

echo "==> build_millie: packaging branded Millie.app"
"$ROOT/package_mori.sh"

echo "==> build_millie: complete — Millie.app in the build tree"

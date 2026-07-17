# Chromium update runbook (automated pipeline)

The scheduled updater session follows this. Goal: new upstream
`ungoogled-chromium-macos` release → ported, built, smoke-tested, and presented
as a PR + draft notes for Danny's approval. **Never publish the release without
explicit approval** — end with a notification instead.

## 0. Detect

```
./check_chromium_update.sh     # "UP_TO_DATE x" → stop. "NEW <tag>" → continue.
```

## 1. Prep the tree

Work in `~/mori-browser-build` (ROOT). `build/src` is the current source tree.
For a version bump you need a fresh upstream tree at the new tag:

- Follow ungoogled-chromium-macos's own build docs for the checkout +
  `ungoogled patches + domain substitution` phase (their `build.sh` up to,
  but not including, the actual compile). Use the venv at `ROOT/buildpy`
  (`PATH=ROOT/buildpy/bin:...` — system python is too old for depot_tools).
- Then `millie/apply_millie.sh`:
  - ditto's the overlay into `chrome/browser/ui/mori/` (always succeeds),
  - applies `chromium-tree.patch`. **Exit 3 = drift** — one of the ~18 in-tree
    files changed upstream. Reconcile hunk-by-hunk (the 149→150 port notes in
    the repo history / PR #22-era commits show the pattern: BUILD.gn target
    lists, BrowserWindow interface drift, command controller hook, CCBC hooks
    for adblock + external URLs). Also re-apply `adblock-tree.patch`
    (3-arg MaybeProxyAdblock + BUILD.gn sources) and
    `menu-commands-tree.patch` / `external-url-tree.patch` if not yet folded in.
- Known API-drift hotspots: `mori_browser_window.h/mm` (BrowserWindow pure
  virtuals appear/disappear — add stubs, drop stale `override`s),
  `GURL::host()` returns `std::string_view` (no `.c_str()`),
  `input::NativeWebKeyboardEvent` namespacing.

## 2. Build

```
./resume_build_150.sh      # gn gen → ninja chrome chromedriver → package_mori.sh
```

(Rename per version as needed; multi-hour on a cold tree, ~4 min Swift-only.)
Requires the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
since Chromium 150.

## 3. Smoke test

```
./smoke_test.sh            # must print SMOKE TEST PASS
```

Also sanity-launch and eyeball nothing obvious is broken if interactive.

## 4. Present (do NOT publish)

- Update `CHROMIUM_VERSION` to the new tag.
- Branch + commit the reconciled patches/overlay changes, push, open a PR
  titled `Chromium <version> port` describing every drift resolved.
- Draft release notes (MILLIE_NOTES style) in the PR body.
- Notify Danny: new version ported, build green, smoke test pass, PR link,
  awaiting "ship" (then: squash-merge + `release.sh --publish` with the next
  MILLIE_VERSION; the Sparkle banner delivers to end users automatically).

## Hard rules

- Notarization credential (`millie-notary`) + Developer ID live in the login
  keychain — publish only works on this Mac, and only after Danny approves.
- Never commit `devid/millie-devid.key`.
- Commits end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`;
  PR bodies end with the Claude Code attribution line.
- `pkill -9 Millie` (never `-f 'Millie.app'`) before test launches.

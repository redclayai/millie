# Building & releasing Millie

The build/packaging/release scripts are **canonical in this repo** (`millie/`).
In the local build tree (`~/mori-browser-build/`) the root-level `package_mori.sh`
and `release.sh` are **symlinks** into this directory, so there is a single
source of truth and the two can't drift:

```
~/mori-browser-build/package_mori.sh -> millie/package_mori.sh
~/mori-browser-build/release.sh      -> millie/release.sh
```

(If you set up a fresh build tree, recreate those symlinks — or just run the
scripts from `millie/`.)

## Pipeline

```
ninja -j16 -C out/Default chrome      # 1. build Chromium + the Swift overlay
./package_mori.sh                     # 2. -> ~/Downloads/Millie.app (ad-hoc signed, for local testing)
MILLIE_VERSION=X.Y ./release.sh --publish   # 3. Developer-ID sign + notarize + staple,
                                            #    build/sign the DMG, update appcast.xml,
                                            #    publish the GitHub release (Sparkle auto-update)
```

- **`apply_millie.sh`** re-applies the overlay + `chromium-tree.patch` onto a
  freshly-prepped `build/src` (before `gn gen`). The overlay itself
  (`overlay/`) is copied into `build/src/chrome/browser/ui/mori` for the build.
- **`package_mori.sh`** wires overlay resources (icons, fonts, glyphs, the
  phishing `threatlist.bin`, and the Widevine CDM zip) into the app bundle,
  brands it "Millie", and ad-hoc signs it for local testing.
- **`release.sh`** honors `MILLIE_VERSION`, `MILLIE_NOTES` (GitHub release body),
  and `MILLIE_NOTES_HTML` (Sparkle changelog). Notes live in `vX.Y-notes.md`.

## Notes

- Version-test builds from `package_mori.sh` are **ad-hoc signed** — never leave
  one in `/Applications`, or Sparkle "Check for Updates" breaks (it refuses an
  update signed by a different identity than the running app). Install the
  notarized build from `dist/` (or the DMG) for real use.
- Signing/notarization secrets are NOT in these scripts: the Developer ID lives
  in the login keychain, the notary profile is `millie-notary`, and the Sparkle
  EdDSA private key is in the keychain (only the public key is in `release.sh`).
  `.gitignore` excludes `devid/`, `*.key`, `dist/`, and `*.dmg`.

# Profiles & Space isolation — design & plan

Goal: Arc-style **Profiles**. A Profile is an isolated browsing identity
(separate cookies, cache, localStorage/IndexedDB, autofill, logins,
extensions). Spaces are organizational and are *assigned to* a Profile;
**many Spaces can share one Profile** (N Spaces → 1 Profile). Confirmed against
Arc's own UI ("Profiles help keep your data separate across Spaces … use any
Profile across one or more Spaces").

## Data model (Arc-accurate)
- `BrowserProfile { id, name, icon }` — first-class, user-managed list, with a
  built-in **Default**. Maps 1:1 to a persistent Chromium `Profile`.
- Each `BrowserContext` (Space) gains a `profileID`. Default Spaces point at the
  Default profile. Re-assignable in Settings.
- Isolation is per **Profile**, NOT per Space. Spaces sharing a profileID share
  one cookie jar / cache / Browser.
- Per-profile settings (Arc parity): search engine, downloads dir, archive
  timer, privacy, passwords, credit cards, notifications, clear-data.

## Live-object mapping (the key simplification vs the old draft)
- One Chromium `Browser` per **distinct in-use Profile**, created lazily when a
  Space using that profile first becomes active — NOT one per Space. Count of
  live Browsers = number of distinct profiles across open Spaces.
- `g_mori_browser` → "active Browser" = the Browser for the active Space's
  profile. Switching to a Space switches to its profile's Browser.
- A Space's tabs' WebContents are created in its profile's Browser; sharing a
  profile means sharing that Browser + storage.

## Why this is a core change, not an overlay tweak

Mori embeds Chromium as a SINGLE `Browser`:
- `g_mori_browser` (one `Browser`) → one `Profile` → one `TabStripModel`.
- Every tab's WebContents is created via `Navigate(g_mori_browser, url, …)`
  (`mori_chrome_bridge.mm` `maybeCreateTab`), so it lives in that one profile's
  default `StoragePartition`.
- Contexts (`BrowserContext` in Contexts.swift) are a Mori-side grouping of tab
  IDs only — they do NOT touch Chromium storage.
- ~30 call sites assume the `g_mori_browser` singleton (tab strip ops, the
  TabStripModel observer, `ViewMap`/`OrphanMap`, MoriPrivacy clear-data,
  permission-prompt factory, devtools, downloads).

A `Browser` is bound to exactly one `Profile`. So real isolation = more than one
profile, which means more than one `Browser`, which means unwinding the
singleton. That is the whole lift.

## Options

### A. Persistent profile per context  ← matches the request
- Create a persistent `Profile` per context via
  `g_browser_process->profile_manager()` under e.g.
  `<user-data-dir>/MillieSpaces/<contextID>`. Creation is ASYNC
  (`CreateProfileAsync`/`LoadProfileByPath`) — must await readiness before
  opening tabs.
- Model: keep one `Browser` per loaded context (multi-Browser). `g_mori_browser`
  becomes "active Browser"; switching space swaps which Browser the
  `MoriBrowserWindow` shows. Bridge singletons become per-Browser/keyed.
- WebContents: create against the context's profile and insert into that
  profile's `Browser` tab strip (thread the context's profile into
  `MoriBrowserView`; tabs already know their context).
- Persistence: map contextID→profile dir in PersistedSession; on context delete,
  `ProfileManager::ScheduleProfileForDeletion`.
- Gives: separate logins/cookies/cache/autofill per space, surviving restart.
- Cost: multi-day; highest risk; extensions/downloads/history are per-profile
  (each space has its own extension set unless explicitly shared — affects the
  extensions UI), and every `g_mori_browser->profile()` use must route to the
  active profile (incl. the permission-prompt and read-anything fixes already
  made).

### B. Ephemeral OTR profile per context  ← lighter, not persistent
- `profile->GetOffTheRecordProfile(OTRProfileID::CreateUnique("millie-space-<id>"), true)`.
  Each unique OTR profile has its own in-memory StoragePartition (separate
  cookies/cache/storage), isolated per space.
- Still needs a `Browser` per OTR profile (same multi-Browser refactor), minus
  on-disk persistence and async profile creation (OTR is sync).
- Gives: isolation while running; everything resets on quit (no persistent
  logins). Some features are disabled in OTR.
- Cost: significant (multi-Browser) but less than A; non-persistent.

### C. Custom StoragePartition per context  ← do NOT
- Non-default partitions for normal browser tabs aren't a supported config
  (designed for `<webview>`/guests); breaks downloads, extensions, autofill,
  service workers. Rejected.

## Recommended path (phased; keep current build as fallback)

1. **Spike (½–1 day):** at runtime create a 2nd persistent Profile + 2nd
   `Browser`, open one tab in it, confirm an isolated cookie jar (log into the
   same site in each, verify independent sessions). Validates approach A and
   surfaces every embedding assumption that breaks. No default-behavior change.
2. **De-singleton the bridge:** `g_mori_browser` → an active-Browser registry
   keyed by contextID; make `ViewMap`/`OrphanMap`/the TabStripModel observer
   per-Browser; resolve "active browser" everywhere.
3. **Context lifecycle → profile lifecycle:** create on space-create, activate
   on space-switch, schedule-delete on space-delete; `MoriBrowserView` creates
   its WC in its context's Browser/profile.
4. **Persistence + re-routing:** contextID→profile-dir in the session; route
   `MoriPrivacy`, permission-prompt factory, devtools, downloads to the active
   profile.
5. **Per-profile extensions/downloads** + re-verify the earlier crash fixes
   against multi-profile.

## Risk
Highest of any change so far — it rewrites the embedding core that the working
build (and every prior fix) depends on. Strongly recommend the spike + a git
branch of the overlay before committing the full rebuild, so the current stable
Millie remains the fallback.

## Spike results — PASSED (2026-06-24)
Ran an env-gated diagnostic (MILLIE_PROFILE_SPIKE=1) against out/Default, then
removed it (tree is clean; never shipped, never in the overlay snapshot):
- `ProfileManager::CreateProfileAsync(user_data_dir/MillieSpikeProfile)` created
  a real **persistent** profile on disk (cookies DB, web data, autofill; otr=0).
- profile1 vs profile2 have **distinct StoragePartitions** (the isolation line).
- Cookie round-trip: a cookie set in profile2 appeared ONLY in profile2's jar,
  NOT profile1's → `cookie isolation = PASS (isolated)`.
- `Browser::Create(CreateParams(profile2,…))` succeeded and did **not** hijack
  `g_mori_browser` (the bridge ignores Browsers after the first); app stayed up.

Conclusion: Approach A (persistent profiles + one Browser per in-use profile) is
de-risked end-to-end. Next phase = the real build (de-singleton the bridge to an
active-Browser registry keyed by profile; BrowserProfile model + Space.profileID;
lazy Browser-per-profile; Settings → Profiles UI). Not started — awaiting go.

## IMPLEMENTED & VERIFIED (2026-06-24)
Shipped as overlay-only changes (chromium-tree.patch unchanged):
- C++ (mori_chrome_bridge.mm, MoriBrowserView.h): `MoriBrowserView.profileKey`;
  `MoriBrowserForProfileKey()` lazily makes a persistent Chromium Profile
  (sync `ProfileManager::GetProfile(user_data_dir/"Millie-<id>")`) + a HEADLESS
  Browser (never Show()n) per profile; `maybeCreateTab` routes Navigate into it;
  `MoriModelForContents` (FindBrowserWithTab) reroutes focus/pin/close;
  g_profile_browsers cleaned in OnBrowserWindowDestroyed.
- Swift: `BrowserProfile` model (BrowserContext.swift); `BrowserContext.profileID`
  (optional, back-compat); `BrowserTab.profileKey` → view; BrowserStore.profiles
  + addProfile/renameProfile/deleteProfile/setProfile + profile(for:); new tabs
  stamped from active Space's profile; persisted (PersistedTab.profileKey,
  PersistedSession.profiles, ctx.profileID).
- UI: Profile picker in CreateContextView + ContextEditor; Settings → Profiles
  section (list/add/rename/delete, shows #Spaces).
Verified end-to-end (env-gated throwaway hook, since removed): real path
addProfile→addContext(profileID)→newTab produced an isolated "Millie-<uuid>"
profile dir with its own Cookies DB; CDP confirmed the tab loaded example.com in
it; app stable; default-profile path unregressed. Cookie isolation itself proven
by the earlier spike (distinct Profile → distinct StoragePartition → separate jar).

Known MVP limitations (acceptable; documented): a tab's profile is fixed at
creation (reassigning a Space only affects new tabs); popups/window.open from an
isolated tab route through the primary Browser (default profile); MoriPrivacy
clear-data + extensions act on the default profile only.

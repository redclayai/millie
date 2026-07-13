// Seam between MoriBrowserWindow / chrome internals and the Millie bridge
// (mori_chrome_bridge.mm). ObjC++-includable; pure-C++ callers use only the
// non-ObjC declarations.

#ifndef CHROME_BROWSER_UI_MORI_MORI_CHROME_HOOKS_H_
#define CHROME_BROWSER_UI_MORI_MORI_CHROME_HOOKS_H_

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#endif

#include <string>
#include <vector>

class Browser;
class Profile;
class GURL;

namespace mori {

// First normal Browser becomes the Millie browser; the SwiftUI chrome attaches
// to it. Called from MoriBrowserWindow's ctor/dtor and Show().
void OnBrowserWindowCreated(Browser* browser);
void OnBrowserWindowDestroyed(Browser* browser);
void EnsureMoriUIStarted(Browser* browser);

// The Browser instance the Millie UI drives (null before startup).
Browser* MoriBrowser();

// The active Space's profile — where extension install/management operate, so
// each Profile keeps its own extension set. Set via SetActiveProfileKey (pushed
// from Swift on Space switch); defaults to the primary profile.
Profile* ActiveProfile();
void SetActiveProfileKey(const std::string& key);

// The Browser hosting the active Space's tabs (the headless per-profile Browser
// for the active key, or the primary Browser for the default profile). Its
// active tab matches what the Millie UI shows; use this — not MoriBrowser() —
// whenever resolving the active WebContents in the active profile's context
// (e.g. extension actions), so the WebContents and ActiveProfile() agree.
Browser* ActiveBrowser();

// Load (without creating a Browser) the Profile for a Millie profile key —
// "default"/empty → the primary profile, any other key → the persistent
// "Millie-<key>" profile. Used by cross-profile operations (e.g. install an
// extension into every Profile).
Profile* ProfileForKey(const std::string& key);

// Route externally-opened URLs (link clicks from other apps, `open <url>`,
// the GURL Apple Event) into the Millie UI as tabs in the active Space, and
// bring the window forward. Returns true if Millie handled them (its UI is
// up); false to let Chrome's default open path run (e.g. during early startup).
// Called from app_controller_mac.mm's OpenUrlsInBrowserWithProfile — Chrome's
// default path creates an unobserved Browser whose tab never becomes a Millie
// tab, so the link appears to do nothing.
bool OpenExternalUrls(const std::vector<GURL>& urls);

// Route a Chrome browser command (an IDC_* id) to the matching Millie action
// for the File-menu commands that don't fit the non-Views/Spaces chrome — new
// tab/window/incognito-window, reopen-closed-tab, open-location, close-tab.
// Chrome's own handlers create unobserved windows or assume a Views browser, so
// they do nothing in Millie. Returns true if Millie handled it (its UI is up);
// false to let Chrome's default command run. Called from
// BrowserCommandController::ExecuteCommandWithDisposition.
bool HandleBrowserCommand(int command_id);

#ifdef __OBJC__
// The shared Millie main window (used for GetNativeWindow / dialog parenting).
NSWindow* MoriMainWindow();
#endif

}  // namespace mori

#endif  // CHROME_BROWSER_UI_MORI_MORI_CHROME_HOOKS_H_

// MoriBrowserView implemented on chrome's Browser/TabStripModel/WebContents —
// the same pure-ObjC contract the Millie Swift UI compiles against, now backed
// by the full //chrome layer so the REAL extension system (service workers,
// content scripts, chrome.* APIs) sees Millie's tabs natively. No shims.

#import "chrome/browser/ui/mori/MoriBrowserView.h"
#import "chrome/browser/ui/mori/MoriPrivacy.h"
#import <objc/message.h>
#include "chrome/browser/ui/mori/mori_adblock.h"
#include "chrome/browser/ui/mori/mori_chrome_hooks.h"

#include <algorithm>
#include <cstdlib>
#include <cmath>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/path_service.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/download/download_core_service_factory.h"
#include "chrome/browser/shell_integration.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "chrome/common/chrome_paths.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/find_in_page/find_notification_details.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/spare_render_process_host_manager.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/storage_partition.h"
// Per-Space profile isolation: route each tab's WebContents into a per-profile
// headless Browser (own cookies/cache/storage). See CONTEXT_ISOLATION_DESIGN.md.
#include <map>
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/web_contents_observer.h"
// Auto picture-in-picture (document-PiP) for conferencing apps (Meet/Zoom/Teams).
// Millie attaches the tab helper itself and pre-grants the content setting since
// its headless, Views-less Browser bypasses the usual UI permission flow.
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/picture_in_picture/auto_picture_in_picture_tab_helper.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "base/task/thread_pool.h"
#include "services/network/public/mojom/clear_data_filter.mojom.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

// Swift-exported surface of MoriRoot (MoriRoot.swift).
@interface MoriRoot : NSObject
+ (NSViewController*)makeRootViewController;
+ (void)prepareForTermination;
+ (BOOL)shouldAutoFocusWebContent;
+ (BOOL)handleShortcutEvent:(NSEvent*)event;
+ (void)releaseShortcutEvent:(NSEvent*)event;
+ (BOOL)isReservedShortcutKeyEquivalent:(NSString*)keyEquivalent
                           modifierMask:(NSUInteger)modifierMask;
+ (void)newTab;
+ (void)openNewTabWithURL:(NSString*)url;
+ (void)openExternalSchemeWithURL:(NSString*)url;
+ (void)newWindow;
+ (void)newPrivateWindow;
+ (void)reopenClosedTab;
+ (void)focusOmnibox;
+ (void)closeCurrentTab;
+ (void)focusTabWithBrowserIdentifier:(int)identifier;
+ (BOOL)uiReady;
+ (void)goBack;
+ (void)goForward;
+ (void)toggleSidebar;
// Menu-bar command targets (see HandleBrowserCommand). All defined in
// MoriRoot.swift and safe no-ops when there is no active tab/store.
+ (void)reload;
+ (void)forceReload;
+ (void)stop;
+ (void)goHome;
+ (void)zoomIn;
+ (void)zoomOut;
+ (void)resetZoom;
+ (void)toggleFindBar;
+ (void)findNext;
+ (void)findPrevious;
+ (void)toggleDevTools;
+ (void)printPage;
+ (void)selectNextTab;
+ (void)selectPreviousTab;
+ (void)duplicateCurrentTab;
+ (void)togglePinCurrentTab;
+ (void)toggleMuteCurrentTab;
+ (void)closeTabsToRightOfCurrent;
+ (void)newSplit;
@end

@class MoriBrowserView;

@interface MoriBrowserView (MoriFocusPrivate)
- (BOOL)canReceiveBrowserFocus;
- (BOOL)containsEventLocation:(NSEvent*)event;
- (BOOL)ownsFirstResponder:(NSResponder*)responder;
@end

@interface NSView (MoriRendererKeyForwarding)
- (NSInteger)keyEvent:(NSEvent*)event;
@end

// Menu delegate that keeps Millie's retargeted main-menu commands enabled and
// pointed at MoriRoot. It re-applies on every open (menuNeedsUpdate: fires
// synchronously, before AppKit's automatic enabling), so it beats Chrome's
// continuous command-state pushes that otherwise grey these items back out.
// Installed on each submenu that holds a mapped command (see +installOnMainMenu),
// chaining any existing delegate (e.g. the History/Tab/Bookmark bridges).
@interface MoriMenuEnabler : NSObject <NSMenuDelegate>
@property(nonatomic, weak) id<NSMenuDelegate> previousDelegate;
+ (void)installOnMainMenu;
@end

// ---------------------------------------------------------------------------
// Globals

namespace {

constexpr int kMoriMediaWorldId = ISOLATED_WORLD_ID_CHROME_INTERNAL;

Browser* g_mori_browser = nullptr;
// Headless Browsers backing non-default Spaces, keyed by Millie profile id.
// Each is bound to its own persistent Chromium Profile (isolated cookies/cache/
// storage) and is never shown — its tabs' native views are reparented into the
// single visible Millie window. Created lazily; erased when the Browser dies.
base::NoDestructor<std::map<std::string, Browser*>> g_profile_browsers;
// The active Space's profile key, pushed from Swift on context switch. Resolves
// which profile extension install/enumeration/management operate on, so each
// Profile keeps its own extension set (Arc model). "default" = primary profile.
base::NoDestructor<std::string> g_active_profile_key("default");
// True while a MoriBrowserView is synchronously creating its own tab via
// Navigate() — the TabStripModel insert observer must not treat that insert
// as an engine-created orphan (it fires before the view can register).
bool g_self_insert_in_progress = false;
NSWindow* __strong g_main_window = nil;
BOOL g_web_content_suppressed = NO;
int g_next_browser_identifier = 1;
// When YES, hiding a tab with a playing video pops it out to Picture-in-Picture
// (driven from -setPageHidden:). Mirrors BrowserSettings.autoPiP.
BOOL g_mori_auto_pip = YES;

// M151 replaced chrome::FindBrowserWithTab (returned Browser*) with
// GlobalBrowserCollection::FindBrowserWithTab, which returns the newer
// BrowserWindowInterface*. We still need the concrete Browser* (as a
// WebContentsDelegate / for tab_strip_model()), so bridge through the
// migration accessor. Null-safe so the callers' `if (Browser* x = ...)`
// guards keep working.
Browser* MoriFindBrowserWithTab(content::WebContents* wc) {
  BrowserWindowInterface* bwi =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(wc);
  return bwi ? static_cast<Browser*>(bwi) : nullptr;  // 154: Browser still derives from BrowserWindowInterface
}

// Pre-grant the AUTO_PICTURE_IN_PICTURE content setting to ALLOW for the major
// video-conferencing origins so Chrome's AutoPictureInPictureTabHelper will
// auto-open a document-PiP window when the user switches away from the call tab.
//
// Why seed instead of relying on the default ("ask") + media-engagement:
//   * In an Incognito/OTR Space, "ask" is treated as BLOCK by the tab helper
//     (IsEligibleForAutoPictureInPicture), so conferencing PiP would never fire.
//   * The normal "ask" -> allow path shows AutoPipSettingHelper's overlay bubble,
//     which is a Views UI Millie's headless (Views-less) Browser can't present.
//   * ALLOW also lets MeetsMediaEngagementConditions() short-circuit for the
//     video-playback path without accrued media engagement.
// Seeding ALLOW makes auto-PiP deterministic for these hosts across every Space.
//
// Idempotent: re-setting the same (pattern, ALLOW) value is a no-op, and we also
// skip profiles we've already seeded this session. Must run on the UI thread
// (HostContentSettingsMap requirement) — all callers are UI-thread browser setup.
void MoriSeedAutoPipContentSettings(Profile* profile) {
  if (!profile) {
    return;
  }
  static base::NoDestructor<std::set<Profile*>> seeded;
  if (!seeded->insert(profile).second) {
    return;  // Already seeded this Profile.
  }
  HostContentSettingsMap* settings_map =
      HostContentSettingsMapFactory::GetForProfile(profile);
  if (!settings_map) {
    return;
  }
  // `[*.]host` matches the host and all its subdomains; plain host matches only
  // that host. Secondary pattern is Wildcard so it matches the tab helper's
  // GetContentSetting(url, url, ...) lookup regardless of scoping.
  static const char* const kConferencingPatterns[] = {
      "https://meet.google.com",     // Google Meet
      "https://[*.]zoom.us",         // Zoom (zoom.us + *.zoom.us)
      "https://teams.microsoft.com", // Microsoft Teams (work/school)
      "https://teams.live.com",      // Microsoft Teams (personal)
      "https://[*.]webex.com",       // Cisco Webex (webex.com + *.webex.com)
  };
  for (const char* spec : kConferencingPatterns) {
    ContentSettingsPattern primary = ContentSettingsPattern::FromString(spec);
    if (!primary.IsValid()) {
      NSLog(@"MORI autopip: invalid content-setting pattern %s", spec);
      continue;
    }
    settings_map->SetContentSettingCustomScope(
        primary, ContentSettingsPattern::Wildcard(),
        ContentSettingsType::AUTO_PICTURE_IN_PICTURE, CONTENT_SETTING_ALLOW);
  }
  NSLog(@"MORI autopip: seeded AUTO_PICTURE_IN_PICTURE=ALLOW for conferencing "
        @"hosts on profile=%p (otr=%d)",
        profile, profile->IsOffTheRecord());
}

std::map<content::WebContents*, __weak MoriBrowserView*>& ViewMap() {
  static base::NoDestructor<
      std::map<content::WebContents*, __weak MoriBrowserView*>>
      map;
  return *map;
}

// Tabs created by the engine (window.open, chrome.tabs.create) waiting for a
// MoriBrowserView to adopt them, keyed by their URL spec. `stashed_at` bounds
// how long an orphan may be adopted: the designated adopter (created via a
// PostTask openNewTabWithURL the same tick) claims it within a moment, so a
// stale orphan is one whose adopter never came — and adopting it under an
// UNRELATED tab that realizes later is the "tab hijacked another tab's page"
// bug (a lingering window.open/e-sign popup surfacing under, say, an n8n tab).
struct OrphanEntry {
  content::WebContents* contents;
  base::TimeTicks stashed_at;
};
std::multimap<std::string, OrphanEntry>& OrphanMap() {
  static base::NoDestructor<std::multimap<std::string, OrphanEntry>> map;
  return *map;
}

// An orphan older than this is never adopted (it's pruned instead). Generous
// enough to cover the adopter tab's create→mount→realize hop, tight enough
// that a truly abandoned popup can't hijack a tab the user opens seconds later.
constexpr base::TimeDelta kOrphanAdoptTTL = base::Seconds(12);

NSMutableArray<MoriBrowserView*>* AllViews() {
  static NSMutableArray* views = [NSMutableArray array];
  return views;
}

void DetachMoriWebContentsDelegates(Browser* browser) {
  if (!browser) {
    return;
  }
  for (auto& entry : ViewMap()) {
    content::WebContents* contents = entry.first;
    if (contents && contents->GetDelegate() == BrowserWebContentsDelegate::From(browser)) {
      contents->SetDelegate(nullptr);
    }
  }
  for (auto& entry : OrphanMap()) {
    content::WebContents* contents = entry.second.contents;
    if (contents && contents->GetDelegate() == BrowserWebContentsDelegate::From(browser)) {
      contents->SetDelegate(nullptr);
    }
  }
}

MoriBrowserView* ActiveMoriBrowserView() {
  if (!g_mori_browser) {
    return nil;
  }
  content::WebContents* contents =
      g_mori_browser->tab_strip_model()->GetActiveWebContents();
  if (!contents) {
    return nil;
  }
  auto it = ViewMap().find(contents);
  return it == ViewMap().end() ? nil : it->second;
}

// In split view two web views are on screen at once. Key events must go to the
// pane that actually holds keyboard focus (the one the user clicked into), not
// always the active tab's pane — otherwise copy/paste/undo typed in the right
// pane land on the left one.
MoriBrowserView* FirstFocusableMoriBrowserView() {
  NSResponder* focused = NSApp.keyWindow.firstResponder;
  if (focused) {
    for (MoriBrowserView* view in [AllViews() reverseObjectEnumerator]) {
      if ([view canReceiveBrowserFocus] && [view ownsFirstResponder:focused]) {
        return view;
      }
    }
  }
  MoriBrowserView* active = ActiveMoriBrowserView();
  if ([active canReceiveBrowserFocus]) {
    return active;
  }
  for (MoriBrowserView* view in [AllViews() reverseObjectEnumerator]) {
    if ([view canReceiveBrowserFocus]) {
      return view;
    }
  }
  return nil;
}

MoriBrowserView* MoriBrowserViewForEvent(NSEvent* event) {
  for (MoriBrowserView* view in [AllViews() reverseObjectEnumerator]) {
    if ([view containsEventLocation:event]) {
      return view;
    }
  }
  return nil;
}

bool HandleNavigationMouseButton(NSEvent* event, bool performNavigation) {
  if (event.type != NSEventTypeOtherMouseDown &&
      event.type != NSEventTypeOtherMouseUp) {
    return false;
  }

  MoriBrowserView* view = MoriBrowserViewForEvent(event);
  switch (event.buttonNumber) {
    case 3:
      if (performNavigation) {
        if (view) {
          [view goBack];
        } else {
          [MoriRoot goBack];
        }
      }
      return true;
    case 4:
      if (performNavigation) {
        if (view) {
          [view goForward];
        } else {
          [MoriRoot goForward];
        }
      }
      return true;
    default:
      return false;
  }
}

bool IsNativeTextInputFirstResponder(NSResponder* responder) {
  return [responder isKindOfClass:[NSTextView class]] ||
         [responder isKindOfClass:[NSTextField class]];
}

NSMenu* FindTopLevelMenu(NSString* title) {
  NSMenu* mainMenu = NSApp.mainMenu;
  if (!mainMenu) {
    return nil;
  }
  for (NSMenuItem* item in mainMenu.itemArray) {
    if ([item.title isEqualToString:title] && item.submenu) {
      return item.submenu;
    }
  }
  return nil;
}

NSMenu* EnsureTopLevelMenu(NSString* title, NSInteger preferredIndex) {
  NSMenu* mainMenu = NSApp.mainMenu;
  if (!mainMenu) {
    return nil;
  }
  if (NSMenu* existing = FindTopLevelMenu(title)) {
    return existing;
  }

  NSMenuItem* item =
      [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
  NSMenu* submenu = [[NSMenu alloc] initWithTitle:title];
  item.submenu = submenu;
  NSInteger index = std::max<NSInteger>(
      0, std::min<NSInteger>(preferredIndex, mainMenu.numberOfItems));
  [mainMenu insertItem:item atIndex:index];
  return submenu;
}

void EnsureMenuAction(NSMenu* menu,
                      NSString* title,
                      SEL action,
                      NSString* keyEquivalent,
                      NSEventModifierFlags modifiers) {
  if (!menu) {
    return;
  }

  NSMenuItem* item = nil;
  for (NSMenuItem* candidate in menu.itemArray) {
    if (candidate.action == action) {
      item = candidate;
      break;
    }
  }
  if (!item) {
    item = [[NSMenuItem alloc] initWithTitle:title
                                      action:action
                               keyEquivalent:keyEquivalent];
    [menu addItem:item];
  }

  item.title = title;
  item.target = nil;
  item.action = action;
  item.keyEquivalent = keyEquivalent;
  item.keyEquivalentModifierMask = modifiers;
}

void InstallStandardEditMenuShortcuts() {
  NSMenu* editMenu = EnsureTopLevelMenu(@"Edit", 1);
  if (!editMenu) {
    return;
  }

  EnsureMenuAction(editMenu, @"Undo", @selector(undo:), @"z",
                   NSEventModifierFlagCommand);
  EnsureMenuAction(editMenu, @"Redo", @selector(redo:), @"z",
                   NSEventModifierFlagCommand | NSEventModifierFlagShift);
  EnsureMenuAction(editMenu, @"Cut", @selector(cut:), @"x",
                   NSEventModifierFlagCommand);
  EnsureMenuAction(editMenu, @"Copy", @selector(copy:), @"c",
                   NSEventModifierFlagCommand);
  EnsureMenuAction(editMenu, @"Paste", @selector(paste:), @"v",
                   NSEventModifierFlagCommand);
  EnsureMenuAction(editMenu, @"Select All", @selector(selectAll:), @"a",
                   NSEventModifierFlagCommand);
}

// Maps a standard Chrome main-menu command id to the MoriRoot class selector
// that performs the equivalent Millie action, or nullptr if Millie has no
// equivalent (those items are left as-is / disabled on purpose). Returns no-arg
// selectors on MoriRoot (all @objc static funcs), matching the Toggle Sidebar
// retargeting below.
// Maps a Chrome main-menu IDC command tag to the matching MoriRoot *class*
// selector (0-arg @objc static funcs). These are dispatched/validated with an
// explicit target = [MoriRoot class] (see applyToMenu:), exactly like the
// working "Toggle Sidebar" item — NOT via the responder chain. Millie's visible
// window is a plain NSWindow with no Views CommandDispatchingWindow, so target=nil
// commandDispatch: items find no handler and AppKit greys them out; an explicit
// class target that responds to the selector validates YES and fires directly.
SEL MoriSelectorForCommand(NSInteger tag) {
  switch (tag) {
    // Edit ▸ Find
    case IDC_FIND:                 return @selector(toggleFindBar);
    case IDC_FIND_NEXT:            return @selector(findNext);
    case IDC_FIND_PREVIOUS:        return @selector(findPrevious);
    case IDC_FOCUS_SEARCH:         return @selector(focusOmnibox);
    // View ▸ reload / stop / zoom
    case IDC_STOP:                 return @selector(stop);
    case IDC_RELOAD:               return @selector(reload);
    case IDC_RELOAD_BYPASSING_CACHE:
    case IDC_RELOAD_CLEARING_CACHE: return @selector(forceReload);
    case IDC_ZOOM_PLUS:            return @selector(zoomIn);
    case IDC_ZOOM_MINUS:           return @selector(zoomOut);
    case IDC_ZOOM_NORMAL:          return @selector(resetZoom);
    // View ▸ Developer
    case IDC_DEV_TOOLS:
    case IDC_DEV_TOOLS_INSPECT:
    case IDC_DEV_TOOLS_CONSOLE:    return @selector(toggleDevTools);
    // File ▸ Print, Close Tab
    case IDC_PRINT:
    case IDC_BASIC_PRINT:          return @selector(printPage);
    case IDC_CLOSE_TAB:            return @selector(closeCurrentTab);
    // History ▸ Home / Back / Forward
    case IDC_HOME:                 return @selector(goHome);
    case IDC_BACK:                 return @selector(goBack);
    case IDC_FORWARD:              return @selector(goForward);
    // Tab menu
    case IDC_CYCLE_TO_NEXT_TAB:    return @selector(selectNextTab);
    case IDC_CYCLE_TO_PREV_TAB:    return @selector(selectPreviousTab);
    case IDC_DUPLICATE_TAB:
    case IDC_DUPLICATE_TARGET_TAB: return @selector(duplicateCurrentTab);
    case IDC_WINDOW_MUTE_SITE:
    case IDC_MUTE_TARGET_SITE:     return @selector(toggleMuteCurrentTab);
    case IDC_WINDOW_PIN_TAB:
    case IDC_PIN_TARGET_TAB:       return @selector(togglePinCurrentTab);
    case IDC_WINDOW_CLOSE_TABS_TO_RIGHT:
                                   return @selector(closeTabsToRightOfCurrent);
    case IDC_NEW_SPLIT_TAB:        return @selector(newSplit);
    default:                       return nullptr;
  }
}

// Run the MoriRoot action for a Chrome main-menu command tag. Returns true if
// the tag is a browser command Millie services (and dispatched it), false
// otherwise. MoriSelectorForCommand is the single source of truth for the
// mapping; every selector it returns is a 0-arg, void @objc class method on
// MoriRoot, so a plain objc_msgSend invokes it.
bool MoriRunBrowserCommand(NSInteger tag) {
  SEL sel = MoriSelectorForCommand(tag);
  if (!sel) {
    return false;
  }
  using MoriVoidClassMethod = void (*)(id, SEL);
  ((MoriVoidClassMethod)objc_msgSend)((id)[MoriRoot class], sel);
  return true;
}

// Re-point the standard Chrome main-menu items that Millie can service directly
// at MoriRoot class selectors, exactly as InstallSidebarMenuShortcut does for
// Toggle Sidebar. This is the only menu path that works in Millie: the visible
// window is a plain NSWindow (no Views CommandDispatchingWindow), so Chrome's
// `commandDispatch:` items have no reachable command handler and AppKit greys
// them out. An explicit target+action is validated/dispatched directly against
// [MoriRoot class], independent of the key window, so the items light up and
// invoke the matching SwiftUI action. Items with no Millie equivalent (Save
// Page As, View Source, Bookmark This/All Tab, Cast, Group Tab, Move Tab to New
// Window, Search Tabs, …) are left untouched and stay disabled on purpose.
[[maybe_unused]] void InstallMillieMenuActions() {
  [MoriMenuEnabler installOnMainMenu];
}

void InstallSidebarMenuShortcut() {
  NSMenu* mainMenu = NSApp.mainMenu;
  if (!mainMenu) {
    return;
  }

  NSMenuItem* existingToggle = nil;
  NSMenu* viewMenu = nil;
  NSMutableArray<NSMenu*>* pendingMenus =
      [NSMutableArray arrayWithObject:mainMenu];
  while (pendingMenus.count > 0) {
    NSMenu* menu = pendingMenus.lastObject;
    [pendingMenus removeLastObject];
    for (NSMenuItem* item in menu.itemArray) {
      NSString* key = item.keyEquivalent.lowercaseString ?: @"";
      NSEventModifierFlags modifiers =
          item.keyEquivalentModifierMask &
          (NSEventModifierFlagCommand | NSEventModifierFlagShift |
           NSEventModifierFlagOption | NSEventModifierFlagControl);
      // Strip key equivalents Millie owns so Chromium menu accelerators never
      // intercept them before the Swift shortcut registry. The reservations
      // live beside the shortcut declarations in ShortcutRegistry.swift.
      if ([MoriRoot isReservedShortcutKeyEquivalent:key
                                      modifierMask:modifiers]) {
        item.keyEquivalent = @"";
      }
      if ([item.title isEqualToString:@"Toggle Sidebar"]) {
        existingToggle = item;
      }
      if ([item.title isEqualToString:@"View"] && item.submenu) {
        viewMenu = item.submenu;
      }
      if (item.submenu) {
        [pendingMenus addObject:item.submenu];
      }
    }
  }

  if (!viewMenu) {
    NSMenuItem* viewItem =
        [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    viewItem.submenu = viewMenu;
    [mainMenu addItem:viewItem];
  }

  NSMenuItem* item = existingToggle;
  if (!item) {
    item = [[NSMenuItem alloc] initWithTitle:@"Toggle Sidebar"
                                      action:@selector(toggleSidebar)
                               keyEquivalent:@"s"];
    [viewMenu insertItem:item atIndex:0];
  }
  item.target = (id)[MoriRoot class];
  item.action = @selector(toggleSidebar);
  item.keyEquivalent = @"";
  item.keyEquivalentModifierMask = 0;
}

id NSObjectFromValue(const base::Value& value) {
  switch (value.type()) {
    case base::Value::Type::NONE:
      return [NSNull null];
    case base::Value::Type::BOOLEAN:
      return @(value.GetBool());
    case base::Value::Type::INTEGER:
      return @(value.GetInt());
    case base::Value::Type::DOUBLE:
      return @(value.GetDouble());
    case base::Value::Type::STRING:
      return base::SysUTF8ToNSString(value.GetString());
    case base::Value::Type::LIST: {
      NSMutableArray* array = [NSMutableArray array];
      for (const base::Value& item : value.GetList()) {
        [array addObject:NSObjectFromValue(item)];
      }
      return array;
    }
    case base::Value::Type::DICT: {
      NSMutableDictionary* dict = [NSMutableDictionary dictionary];
      for (auto pair : value.GetDict()) {
        dict[base::SysUTF8ToNSString(pair.first)] =
            NSObjectFromValue(pair.second);
      }
      return dict;
    }
    case base::Value::Type::BINARY:
      return [NSNull null];
  }
  return [NSNull null];
}

}  // namespace

@implementation MoriMenuEnabler

@synthesize previousDelegate = _previousDelegate;

// NSMenu.delegate is a weak reference, so keep our enablers alive for the app
// lifetime.
static NSMutableArray<MoriMenuEnabler*>* MoriMenuEnablers() {
  static NSMutableArray<MoriMenuEnabler*>* enablers = [NSMutableArray array];
  return enablers;
}

+ (void)installOnMainMenu {
  NSMenu* mainMenu = NSApp.mainMenu;
  if (!mainMenu) {
    return;
  }
  // Walk every menu/submenu; on each one that holds at least one command Millie
  // services, ensure our enabler is the delegate and re-apply the retargeting.
  NSMutableArray<NSMenu*>* pending = [NSMutableArray arrayWithObject:mainMenu];
  while (pending.count > 0) {
    NSMenu* menu = pending.lastObject;
    [pending removeLastObject];
    BOOL hasMapped = NO;
    for (NSMenuItem* item in menu.itemArray) {
      if (item.submenu) {
        [pending addObject:item.submenu];
      }
      if (MoriSelectorForCommand(item.tag) && !item.isAlternate) {
        hasMapped = YES;
      }
    }
    if (!hasMapped) {
      continue;
    }
    // If our enabler is already this menu's delegate (Chrome hasn't rebuilt it),
    // just re-apply. Otherwise wrap the current delegate so Chrome's dynamic
    // bridges still run, then apply.
    if ([menu.delegate isKindOfClass:[MoriMenuEnabler class]]) {
      [(MoriMenuEnabler*)menu.delegate applyToMenu:menu];
      continue;
    }
    MoriMenuEnabler* enabler = [[MoriMenuEnabler alloc] init];
    enabler.previousDelegate = menu.delegate;  // chain any existing bridge
    [MoriMenuEnablers() addObject:enabler];
    menu.delegate = enabler;
    [enabler applyToMenu:menu];
  }

  // Chrome rebuilds the main menu and restores its own disabled commandDispatch:
  // items whenever the app is activated / a window becomes main (AppController's
  // windowDidBecomeMain: path). Re-run this walk on those notifications — they
  // fire reliably for a menu-bar app, and because Chrome's AppController
  // registered its observers first, ours runs afterward and wins. (The menu bar
  // is drawn by the system, so NSMenuDidBeginTracking is not posted for it.)
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    void (^reapply)(NSNotification*) = ^(NSNotification* note) {
      [MoriMenuEnabler installOnMainMenu];
    };
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:reapply];
    [nc addObserverForName:NSWindowDidBecomeMainNotification
                    object:nil
                     queue:nil
                usingBlock:reapply];
  });
}

// Swap each mapped Chrome command item for a fresh plain NSMenuItem targeting
// [MoriRoot class] (the Toggle Sidebar pattern — the only menu wiring that works
// in Millie's plain-NSWindow setup). Re-applied on each open in case Chrome
// rebuilds the items.
- (void)applyToMenu:(NSMenu*)menu {
  // Collect the mapped Chrome items first (don't mutate while iterating).
  NSMutableArray<NSMenuItem*>* toReplace = [NSMutableArray array];
  for (NSMenuItem* item in menu.itemArray) {
    if (item.isAlternate) {
      continue;
    }
    if (MoriSelectorForCommand(item.tag)) {
      [toReplace addObject:item];
    }
  }
  // Replace each Chrome-built command item with a fresh, plain NSMenuItem
  // targeting [MoriRoot class] — exactly like the working Toggle Sidebar item.
  // Mutating the existing Chrome item (target/action/enabled/tag) does NOT
  // stick: Chrome rebuilds these menus (on app activation / when a browser
  // window becomes key) and restores its own disabled commandDispatch: items,
  // dropping both our edits and our delegate. We therefore re-run this on every
  // menu-bar tracking session (see the NSMenuDidBeginTracking observer), which
  // fires after Chrome's rebuild. A fresh item Chrome does not own stays
  // enabled and dispatches straight to MoriRoot.
  for (NSMenuItem* oldItem in toReplace) {
    NSInteger idx = [menu indexOfItem:oldItem];
    if (idx < 0) {
      continue;
    }
    SEL sel = MoriSelectorForCommand(oldItem.tag);
    NSMenuItem* newItem =
        [[NSMenuItem alloc] initWithTitle:oldItem.title
                                   action:sel
                            keyEquivalent:oldItem.keyEquivalent];
    newItem.keyEquivalentModifierMask = oldItem.keyEquivalentModifierMask;
    newItem.target = (id)[MoriRoot class];
    newItem.enabled = YES;
    [menu removeItemAtIndex:idx];
    [menu insertItem:newItem atIndex:idx];
  }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  // Let any chained bridge (History/Tab/Bookmarks) rebuild its dynamic section
  // first, then re-assert our commands on top.
  if ([self.previousDelegate respondsToSelector:@selector(menuNeedsUpdate:)]) {
    [self.previousDelegate menuNeedsUpdate:menu];
  }
  [self applyToMenu:menu];
}

// menuNeedsUpdate: only fires when the menu is marked dirty; menuWillOpen: fires
// on every open, so re-assert here too (this is the one that actually runs when
// the user or AppKit opens the menu).
- (void)menuWillOpen:(NSMenu*)menu {
  if ([self.previousDelegate respondsToSelector:@selector(menuWillOpen:)]) {
    [self.previousDelegate menuWillOpen:menu];
  }
  [self applyToMenu:menu];
}

// Forward all other NSMenuDelegate callbacks to the chained delegate so the
// bridges keep working.
- (id)forwardingTargetForSelector:(SEL)aSelector {
  if ([self.previousDelegate respondsToSelector:aSelector]) {
    return self.previousDelegate;
  }
  return nil;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
  if ([super respondsToSelector:aSelector]) {
    return YES;
  }
  return [self.previousDelegate respondsToSelector:aSelector];
}

@end

// Engine-facing surface of MoriBrowserView (called from the C++ observers).
@interface MoriBrowserView ()
- (void)engineAttachWebContents:(content::WebContents*)webContents;
- (void)engineWebContentsGone;
- (void)engineSetTitle:(NSString*)title;
- (void)engineSetURL:(NSString*)url;
- (void)engineSetFaviconImage:(NSImage*)image iconURL:(NSString*)iconURL;
- (void)engineSetLoading:(BOOL)loading;
- (void)engineNavStateChanged;
- (void)engineFindReplyOrdinal:(int)ordinal count:(int)count;
- (void)engineAudioStateChanged:(BOOL)audible;
- (void)engineRequestsNewTabWithURL:(NSString*)url;
- (void)engineMaybeRefocus;
- (BOOL)canReceiveBrowserFocus;
- (BOOL)focusRendererAndForwardKeyEventIfNeeded:(NSEvent*)event;
- (BOOL)ensureRendererFirstResponderForKeyEvent:(NSEvent*)event;
- (BOOL)forwardRendererEditShortcutIfNeeded:(NSEvent*)event;
- (BOOL)containsEventLocation:(NSEvent*)event;
- (BOOL)ownsFirstResponder:(NSResponder*)responder;
- (void)applySuppressionState;
@end

// Menu target for the "Set as Default Browser…" item in the app menu.
@interface MoriMenuActions : NSObject
- (void)setAsDefaultBrowser:(id)sender;
@end

@implementation MoriMenuActions
- (void)setAsDefaultBrowser:(id)sender {
  // May block on the LaunchServices registration; keep it off the UI thread.
  base::ThreadPool::PostTask(
      FROM_HERE, {base::MayBlock()},
      base::BindOnce([] { shell_integration::SetAsDefaultBrowser(); }));
}
@end

// ---------------------------------------------------------------------------
// Per-view WebContents observer → delegate events

namespace mori {

class TabBridge : public content::WebContentsObserver,
                  public find_in_page::FindResultObserver,
                  public favicon::FaviconDriverObserver {
 public:
  TabBridge(content::WebContents* contents, MoriBrowserView* view)
      : content::WebContentsObserver(contents), view_(view) {
    if (auto* helper = find_in_page::FindTabHelper::FromWebContents(contents)) {
      find_observation_.Observe(helper);
    }
    // Chromium downloads and decodes the page's real favicon (any format) and
    // notifies us here; Swift-side favicon rendering never performs its own
    // network fetch and falls back to a local brand glyph or monogram.
    if (auto* favicon_driver =
            favicon::ContentFaviconDriver::FromWebContents(contents)) {
      favicon_observation_.Observe(favicon_driver);
    }
  }
  ~TabBridge() override = default;

  // content::WebContentsObserver:
  void TitleWasSet(content::NavigationEntry* entry) override {
    [view_ engineSetTitle:base::SysUTF16ToNSString(
                              web_contents()->GetTitle())];
  }

  void PrimaryPageChanged(content::Page& page) override {
    [view_ engineSetURL:base::SysUTF8ToNSString(
                             web_contents()->GetLastCommittedURL().spec())];
    [view_ engineNavStateChanged];
    [view_ engineMaybeRefocus];
  }

  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override {
    if (!navigation_handle->HasCommitted() ||
        !navigation_handle->IsInPrimaryMainFrame() ||
        !navigation_handle->IsSameDocument()) {
      return;
    }
    [view_ engineSetURL:base::SysUTF8ToNSString(
                             navigation_handle->GetURL().spec())];
    [view_ engineNavStateChanged];
  }

  void DidStartLoading() override {
    [view_ engineSetLoading:YES];
  }

  void DidStopLoading() override {
    [view_ engineSetLoading:NO];
    [view_ engineNavStateChanged];
    [view_ engineMaybeRefocus];
  }

  void OnAudioStateChanged(bool audible) override {
    [view_ engineAudioStateChanged:audible];
  }

  void WebContentsDestroyed() override {
    [view_ engineWebContentsGone];
  }

  // find_in_page::FindResultObserver:
  void OnFindResultAvailable(content::WebContents* web_contents) override {
    auto* helper = find_in_page::FindTabHelper::FromWebContents(web_contents);
    if (!helper) {
      return;
    }
    const find_in_page::FindNotificationDetails& result = helper->find_result();
    [view_ engineFindReplyOrdinal:result.active_match_ordinal()
                            count:result.number_of_matches()];
  }

  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override {
    find_observation_.Reset();
  }

  // favicon::FaviconDriverObserver:
  void OnFaviconUpdated(favicon::FaviconDriver* favicon_driver,
                        NotificationIconType notification_icon_type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override {
    // Only the standard 16-DIP page favicon drives the sidebar glyph; ignore
    // the larger touch-icon notifications so a big apple-touch-icon doesn't
    // displace the crisp favicon.
    if (notification_icon_type !=
        favicon::FaviconDriverObserver::NON_TOUCH_16_DIP) {
      return;
    }
    // Chromium's FaviconDriver routinely fires a *spurious empty* update right
    // after delivering the real icon (a secondary candidate, or the in-memory
    // entry, resolving to nothing). Passing that through wiped the crisp
    // favicon and flashed the host monogram ~0.5s after each page load. Drop
    // empty updates here and keep the last good icon; a genuine page change
    // clears it through the navigation-start path instead.
    NSImage* ns_image = image.AsNSImage();
    if (!ns_image) {
      return;
    }
    [view_ engineSetFaviconImage:ns_image
                         iconURL:base::SysUTF8ToNSString(icon_url.spec())];
  }

 private:
  __weak MoriBrowserView* view_;
  base::ScopedObservation<find_in_page::FindTabHelper,
                          find_in_page::FindResultObserver>
      find_observation_{this};
  base::ScopedObservation<favicon::FaviconDriver,
                          favicon::FaviconDriverObserver>
      favicon_observation_{this};
};

// ---------------------------------------------------------------------------
// TabStripModel observer: engine-created tabs (popups, chrome.tabs.create)

class MoriTabStripBridge : public TabStripModelObserver {
 public:
  MoriTabStripBridge() = default;

  void OnTabStripModelChanged(
      TabStripModel* tab_strip_model,
      const TabStripModelChange& change,
      const TabStripSelectionChange& selection) override {
    if (change.type() != TabStripModelChange::kInserted) {
      return;
    }
    if (g_self_insert_in_progress) {
      return;  // A MoriBrowserView is inserting its own tab.
    }
    for (const auto& contents : change.GetInsert()->contents) {
      content::WebContents* wc = contents.contents.get();
      // Delegate to the Browser that actually owns this WebContents (its own
      // profile), so popups/AddNewContents route into the matching tab strip
      // instead of forcing a foreign-profile insert into the primary Browser.
      if (Browser* owner = MoriFindBrowserWithTab(wc)) {
        wc->SetDelegate(BrowserWebContentsDelegate::From(owner));
      } else if (g_mori_browser) {
        wc->SetDelegate(BrowserWebContentsDelegate::From(g_mori_browser));
      }
      if (ViewMap().count(wc)) {
        // A Millie-created tab arrived: the startup blank (if any) can go now
        // without emptying the strip (which would tear the Browser down).
        MaybeCloseStartupBlank();
        continue;
      }
      const GURL url = wc->GetVisibleURL();
      const bool startup_blank =
          ViewMap().empty() &&
          (url.is_empty() || url.spec() == "about:blank" ||
           url.host() == "newtab" || url.host() == "new-tab-page");
      if (startup_blank) {
        // Millie restores its own session; this engine-created NTP is closed as
        // soon as a real tab exists (closing it now would empty the strip and
        // destroy the Browser). Navigate it to about:blank first: the NTP
        // WebUI renderer can't fully connect without Chrome's views window
        // and self-terminates after 15s, which would tear down the tab from
        // under us.
        startup_blank_ = wc;
        wc->GetController().LoadURL(GURL("about:blank"), content::Referrer(),
                                    ui::PAGE_TRANSITION_AUTO_TOPLEVEL,
                                    std::string());
        continue;
      }
      // Engine-created tab (window.open, chrome.tabs.create from extension
      // popups, etc.): stash as orphan and ask the Millie UI to open a tab at
      // that URL; the resulting MoriBrowserView adopts the orphan. Deliver to
      // a view that actually has a navDelegate (background runners may not).
      const std::string spec = url.is_valid() && !url.spec().empty()
                                   ? url.spec()
                                   : std::string("about:blank");
      OrphanMap().emplace(spec, OrphanEntry{wc, base::TimeTicks::Now()});
      // Defer the Millie-side tab creation to the next runloop tick. We are
      // inside TabStripModel::OnTabStripModelChanged — the strip is mid-insert.
      // openNewTab -> peek()/newTab() realizes a WebContents and synchronously
      // mounts its SwiftUI host (withAnimation flushes the transaction now),
      // and that mount runs viewDidMoveToWindow -> engineAttachWebContents ->
      // focusBrowser -> TabStripModel::ActivateTabAt. Mutating the strip from
      // within its own observer trips ValidateNotReentrant and hard-crashes.
      // PostTask runs the creation after this mutation unwinds. The orphan is
      // registered synchronously above, so adoption still matches on the next
      // tick. (v2.39 deferred only peek()'s close(); this covers the whole
      // creation path — close, mount, attach, and activate.)
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce([](std::string s) {
            [MoriRoot openNewTabWithURL:base::SysUTF8ToNSString(s)];
          }, spec));
    }
  }

 private:
  void MaybeCloseStartupBlank() {
    content::WebContents* blank = startup_blank_;
    if (!blank) {
      return;
    }
    startup_blank_ = nullptr;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([](content::WebContents* contents) {
          if (!g_mori_browser) {
            return;
          }
          TabStripModel* model = g_mori_browser->tab_strip_model();
          const int index = model->GetIndexOfWebContents(contents);
          if (index != TabStripModel::kNoTab && model->count() > 1 &&
              !ViewMap().count(contents)) {
            model->CloseWebContentsAt(index, TabCloseTypes::CLOSE_NONE);
          }
        }, blank));
  }

  raw_ptr<content::WebContents> startup_blank_ = nullptr;
};

// The single tab-strip observer, lazily created. Installed on the primary
// Browser and on each isolated Browser so engine-created tabs (window.open
// popups) from any profile become Millie tabs in their own jar.
TabStripModelObserver* MoriTabStripObserver() {
  static MoriTabStripBridge* bridge = new MoriTabStripBridge();
  return bridge;
}

// Feeds Millie's DownloadStore (which listens for the CEF-era
// "MoriDownloadUpdated" NSNotification) from Chrome's real DownloadManager.
class MoriDownloadBridge : public content::DownloadManager::Observer,
                           public download::DownloadItem::Observer {
 public:
  explicit MoriDownloadBridge(content::DownloadManager* manager) {
    manager->AddObserver(this);
  }

  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    item->AddObserver(this);
    Broadcast(item);
  }

  void OnDownloadUpdated(download::DownloadItem* item) override {
    Broadcast(item);
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    item->RemoveObserver(this);
  }

 private:
  void Broadcast(download::DownloadItem* item) {
    const auto state = item->GetState();
    NSDictionary* info = @{
      @"id" : @(item->GetId()),
      @"url" : base::SysUTF8ToNSString(item->GetURL().spec()),
      @"filename" : base::SysUTF8ToNSString(
          item->GetFileNameToReportUser().AsUTF8Unsafe()),
      @"path" : base::SysUTF8ToNSString(
          item->GetTargetFilePath().AsUTF8Unsafe()),
      @"percent" : @(item->PercentComplete()),
      @"received" : @(item->GetReceivedBytes()),
      @"total" : @(item->GetTotalBytes()),
      @"speed" : @(item->CurrentSpeed()),
      @"inProgress" : @(state == download::DownloadItem::IN_PROGRESS),
      @"complete" : @(state == download::DownloadItem::COMPLETE),
      @"canceled" : @(state == download::DownloadItem::CANCELLED ||
                      state == download::DownloadItem::INTERRUPTED),
    };
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"MoriDownloadUpdated"
                      object:nil
                    userInfo:info];
  }
};

content::DownloadManager* MoriDownloadManager() {
  return g_mori_browser
             ? g_mori_browser->GetProfile()->GetDownloadManager()
             : nullptr;
}

// Attach a download bridge to `profile`'s DownloadManager unless we're already
// observing it. Called for the primary profile at startup AND for every
// isolated Space profile as it's created — otherwise downloads started inside
// an isolated Space never reach Millie's DownloadStore, so the header download
// indicator (progress ring + pill) wouldn't appear for them.
void EnsureDownloadObserverForProfile(Profile* profile) {
  if (!profile) {
    return;
  }
  content::DownloadManager* manager = profile->GetDownloadManager();
  if (!manager) {
    return;
  }
  static base::NoDestructor<std::set<content::DownloadManager*>> observed;
  if (!observed->insert(manager).second) {
    return;  // already observing this profile's downloads
  }
  new MoriDownloadBridge(manager);  // self-owned; lives for the process lifetime
}

// Install 1Password's native-messaging host manifest into Millie's Chromium
// user-data dir so the 1Password extension can reach the desktop app (Touch ID
// unlock). 1Password only writes this manifest for browsers it knows about, so
// a custom Chromium never gets one; we stage it ourselves, pointing at the
// installed helper. This is necessary but NOT sufficient — 1Password's
// BrowserSupport still gates the connection on a hardcoded code-signature
// allowlist that must include app.millie (pending an AgileBits allowlist add),
// so this has no user-visible effect until Millie is allowlisted. Harmless
// meanwhile: we only write when 1Password is installed and never clobber an
// existing manifest. The file I/O is posted off the UI thread.
void EnsureOnePasswordNativeMessagingManifest() {
  base::FilePath user_data;
  if (!base::PathService::Get(chrome::DIR_USER_DATA, &user_data)) {
    return;
  }
  base::ThreadPool::PostTask(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
      base::BindOnce(
          [](base::FilePath user_data) {
            const base::FilePath helper(
                "/Applications/1Password.app/Contents/Library/LoginItems/"
                "1Password Browser Helper.app/Contents/MacOS/"
                "1Password-BrowserSupport");
            if (!base::PathExists(helper)) {
              return;  // 1Password desktop app not installed
            }
            const base::FilePath dir =
                user_data.Append("NativeMessagingHosts");
            const base::FilePath manifest =
                dir.Append("com.1password.1password.json");
            if (base::PathExists(manifest)) {
              return;  // don't clobber (1Password may have written it)
            }
            if (!base::CreateDirectory(dir)) {
              return;
            }
            static constexpr char kManifest[] =
                "{\n"
                "  \"name\": \"com.1password.1password\",\n"
                "  \"description\": \"1Password BrowserSupport\",\n"
                "  \"path\": \"/Applications/1Password.app/Contents/Library/"
                "LoginItems/1Password Browser Helper.app/Contents/MacOS/"
                "1Password-BrowserSupport\",\n"
                "  \"type\": \"stdio\",\n"
                "  \"allowed_origins\": [\n"
                "    \"chrome-extension://"
                "hjlinigoblmkhjejkmbegnoaljkphmgo/\",\n"
                "    \"chrome-extension://"
                "bkpbhnjcbehoklfkljkkbbmipaphipgl/\",\n"
                "    \"chrome-extension://"
                "gejiddohjgogedgjnonbofjigllpkmbf/\",\n"
                "    \"chrome-extension://"
                "khgocmkkpikpnmmkgmdnfckapcdkgfaf/\",\n"
                "    \"chrome-extension://"
                "aeblfdkhhhdcdjpifhhbdiojplfjncoa/\",\n"
                "    \"chrome-extension://"
                "dppgmdbiimibapkepcbdbmkaabgiofem/\"\n"
                "  ]\n"
                "}\n";
            base::WriteFile(manifest, std::string_view(kManifest));
          },
          std::move(user_data)));
}

void OnBrowserWindowCreated(Browser* browser) {
  NSLog(@"MORI OnBrowserWindowCreated type=%d existing=%p", (int)browser->GetType(),
        g_mori_browser);
  if (g_mori_browser || browser->GetType() != Browser::TYPE_NORMAL) {
    return;
  }
  g_mori_browser = browser;
  browser->tab_strip_model()->AddObserver(MoriTabStripObserver());
  // Pre-grant auto-PiP for conferencing hosts on the primary (default) profile.
  MoriSeedAutoPipContentSettings(browser->GetProfile());
  EnsureOnePasswordNativeMessagingManifest();
  NSLog(@"MORI adopted browser %p", browser);
}

void OnBrowserWindowDestroyed(Browser* browser) {
  for (auto it = g_profile_browsers->begin(); it != g_profile_browsers->end();
       ++it) {
    if (it->second == browser) {
      g_profile_browsers->erase(it);
      break;
    }
  }
  if (g_mori_browser == browser) {
    DetachMoriWebContentsDelegates(browser);
    g_mori_browser = nullptr;
  }
}

}  // namespace mori  (reopened below after the window class)

// Millie's main window. A plain NSWindow is always the tail of its own responder
// chain — reached after every view but before NSApp / AppController — so it is
// the one place that reliably services Chrome's target=nil `commandDispatch:`
// main-menu items no matter what holds first responder (web content, the SwiftUI
// sidebar, the launcher, or nothing at all). It runs the browser commands Millie
// owns and forwards everything else to AppController so the app-level commands
// (New Tab, New Window, …) keep working exactly as before.
@interface MoriCommandWindow : NSWindow
@end

@implementation MoriCommandWindow
- (void)commandDispatch:(id)sender {
  if (MoriRunBrowserCommand([sender tag])) {
    return;
  }
  id del = NSApp.delegate;
  if ([del respondsToSelector:@selector(commandDispatch:)]) {
    [del commandDispatch:sender];
  }
}
- (void)commandDispatchUsingKeyModifiers:(id)sender {
  if (MoriRunBrowserCommand([sender tag])) {
    return;
  }
  id del = NSApp.delegate;
  if ([del respondsToSelector:@selector(commandDispatchUsingKeyModifiers:)]) {
    [del commandDispatchUsingKeyModifiers:sender];
  }
}
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  SEL action = [item action];
  if (action == @selector(commandDispatch:) ||
      action == @selector(commandDispatchUsingKeyModifiers:)) {
    if (MoriSelectorForCommand([item tag])) {
      return YES;  // a command Millie services — always available
    }
    id del = NSApp.delegate;  // forward app-level commands to AppController
    if ([del respondsToSelector:@selector(validateUserInterfaceItem:)]) {
      return [del validateUserInterfaceItem:item];
    }
    return NO;
  }
  return [super validateUserInterfaceItem:item];
}
@end

namespace mori {

void EnsureMoriUIStarted(Browser* browser) {
  NSLog(@"MORI EnsureMoriUIStarted type=%d window=%p", (int)browser->GetType(),
        g_main_window);
  if (g_main_window || browser->GetType() != Browser::TYPE_NORMAL) {
    return;
  }

  NSWindow* window = [[MoriCommandWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1280, 820)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable |
                          NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.title = @"Millie";
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  // Show the standard macOS window controls (close / minimize / zoom). The
  // SwiftUI sidebar reserves top-left space for them; they live in the titlebar
  // layer above the content, so they stay clickable over the chrome.
  NSButton* closeButton = [window standardWindowButton:NSWindowCloseButton];
  NSButton* miniaturizeButton =
      [window standardWindowButton:NSWindowMiniaturizeButton];
  NSButton* zoomButton = [window standardWindowButton:NSWindowZoomButton];
  NSButton* titlebarButtons[3] = {closeButton, miniaturizeButton, zoomButton};
  for (NSButton* button : titlebarButtons) {
    if (!button) {
      continue;
    }
    button.hidden = NO;
    button.enabled = YES;
    button.alphaValue = 1;
  }
  window.releasedWhenClosed = NO;
  // EXPERIMENT (gated on MORI_ENABLE_GPU_COMPOSITING): under GPU compositing,
  // protected video is forced into an AVSampleBufferDisplayLayer with
  // preventsCapture=YES (ca_renderer_layer_tree.mm). That layer blanks in a
  // non-opaque window → DRM (Netflix) fails. Make the window opaque so the
  // protected layer presents. Test whether this alone fixes DRM under GPU
  // compositing before deciding how to keep it with the rounded/vibrant look.
  if (std::getenv("MORI_ENABLE_GPU_COMPOSITING")) {
    window.opaque = YES;
    window.backgroundColor = NSColor.blackColor;
  }
  window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
  window.contentMinSize = NSMakeSize(720, 480);
  window.contentViewController = [MoriRoot makeRootViewController];
  // Remember the window's size and position across launches. With an autosave
  // name set, AppKit writes the frame to NSUserDefaults on every resize/move
  // and restores it here; setFrameUsingName returns NO on first launch (no
  // saved frame), where we fall back to centering the default 1280x820.
  // AppKit's constrainFrameRect keeps a saved frame on-screen if the display
  // setup changed since last quit.
  [window setFrameAutosaveName:@"MillieMainWindow"];
  if (![window setFrameUsingName:@"MillieMainWindow"]) {
    [window center];
  }
  [window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  g_main_window = window;
  NSLog(@"MORI main window up visible=%d", window.isVisible ? 1 : 0);

  // MoriApplication.sendEvent equivalent: Millie's shortcut registry gets first
  // crack at key events; consume the handled ones.
  [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown |
                                           NSEventMaskKeyUp |
                                           NSEventMaskFlagsChanged |
                                           NSEventMaskLeftMouseDown |
                                           NSEventMaskRightMouseDown |
                                           NSEventMaskOtherMouseDown |
                                           NSEventMaskOtherMouseUp
                                   handler:^NSEvent*(NSEvent* event) {
                                     if (event.type == NSEventTypeKeyDown) {
                                       // ⌘S (toggle sidebar) and ⌘T (toggle
                                       // omnibox) flow through the shared
                                       // shortcut registry below like every
                                       // other shortcut, so they behave
                                       // identically whether chrome or web
                                       // content has focus.
                                       if ([MoriRoot
                                               handleShortcutEvent:event]) {
                                         return nil;
                                       }
                                       if (MoriBrowserView* view =
                                               FirstFocusableMoriBrowserView()) {
                                         if ([view forwardRendererEditShortcutIfNeeded:
                                                   event]) {
                                           return nil;
                                         }
                                         if ([view focusRendererAndForwardKeyEventIfNeeded:
                                                   event]) {
                                           return nil;
                                         }
                                         [view ensureRendererFirstResponderForKeyEvent:
                                                   event];
                                       }
                                     } else if (event.type ==
                                                NSEventTypeKeyUp) {
                                       [MoriRoot releaseShortcutEvent:event];
                                       if (MoriBrowserView* view =
                                               FirstFocusableMoriBrowserView()) {
                                         [view ensureRendererFirstResponderForKeyEvent:
                                                   event];
                                       }
                                     } else if (event.type ==
                                                NSEventTypeFlagsChanged) {
                                       [MoriRoot releaseShortcutEvent:event];
                                     } else if (event.type ==
                                                    NSEventTypeLeftMouseDown ||
                                                event.type ==
                                                    NSEventTypeRightMouseDown ||
                                                event.type ==
                                                    NSEventTypeOtherMouseDown) {
                                       if (MoriBrowserView* view =
                                               MoriBrowserViewForEvent(event)) {
                                         [view focusBrowser];
                                       }
                                       if (HandleNavigationMouseButton(
                                               event, false)) {
                                         return nil;
                                       }
                                     } else if (event.type ==
                                                NSEventTypeOtherMouseUp) {
                                       if (HandleNavigationMouseButton(
                                               event, true)) {
                                         return nil;
                                       }
                                     }
                                     return event;
                                   }];

  [[NSNotificationCenter defaultCenter]
      addObserverForName:NSApplicationWillTerminateNotification
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification* note) {
                DetachMoriWebContentsDelegates(g_mori_browser);
                [MoriRoot prepareForTermination];
              }];

  // Chrome's real downloads → Millie's DownloadStore. The primary profile is
  // observed here; each isolated Space profile is observed as it's created (see
  // MoriBrowserForProfileKey), so downloads in any Space are reflected.
  if (g_mori_browser) {
    EnsureDownloadObserverForProfile(g_mori_browser->GetProfile());
  }

  // "Millie ▸ Set as Default Browser…" in the application menu.
  static MoriMenuActions* menuActions = [[MoriMenuActions alloc] init];
  NSMenu* appMenu = [[NSApp.mainMenu itemAtIndex:0] submenu];
  if (appMenu) {
    NSMenuItem* item =
        [[NSMenuItem alloc] initWithTitle:@"Set as Default Browser…"
                                   action:@selector(setAsDefaultBrowser:)
                            keyEquivalent:@""];
    item.target = menuActions;
    [appMenu insertItem:item atIndex:1];
    [appMenu insertItem:[NSMenuItem separatorItem] atIndex:2];
  }
  InstallStandardEditMenuShortcuts();
  InstallSidebarMenuShortcut();
  // NOTE: InstallMillieMenuActions() is intentionally disabled. Replacing or
  // retagging Chrome's main-menu command items (to retarget them at MoriRoot)
  // does not work — Chrome owns these items, rebuilds them on activation, and
  // dispatches them through commandDispatch: — and it actively CRASHES: removing
  // the IDC_NEW_TAB_TO_RIGHT / IDC_WINDOW_CLOSE_TABS_TO_RIGHT items breaks the
  // CHECK_EQ(count, 2) in -[AppController onVerticalTabStripModeChanged:] on the
  // next window-becomes-main. The correct fix is a commandDispatch:/
  // validateUserInterfaceItem: router in the key window's responder chain backed
  // by MoriRoot (leaving Chrome's items untouched). See follow-up work.
  // InstallMillieMenuActions();
}

NSWindow* MoriMainWindow() {
  return g_main_window;
}

Browser* MoriBrowser() {
  return g_mori_browser;
}

// Links that arrived before MoriRoot's UI existed (cold launch).
static std::vector<std::string>& PendingExternalUrls() {
  static base::NoDestructor<std::vector<std::string>> urls;
  return *urls;
}

// Open every stashed URL as a tab in the active Space, then bring Millie
// forward. If the UI isn't up yet (cold launch), retry on the main queue until
// it is (bounded so a windowless/background launch doesn't spin forever).
static void FlushPendingExternalUrls(int attempts_left) {
  @autoreleasepool {
    if (![MoriRoot uiReady]) {
      if (attempts_left <= 0) {
        PendingExternalUrls().clear();
        return;
      }
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
          dispatch_get_main_queue(),
          ^{ FlushPendingExternalUrls(attempts_left - 1); });
      return;
    }
    std::vector<std::string>& pending = PendingExternalUrls();
    const bool opened = !pending.empty();
    for (const std::string& spec : pending) {
      [MoriRoot openNewTabWithURL:base::SysUTF8ToNSString(spec)];
    }
    pending.clear();
    if (opened && g_main_window) {
      [NSApp activateIgnoringOtherApps:YES];
      [g_main_window makeKeyAndOrderFront:nil];
    }
  }
}

void OnBrowserActivateRequested(Browser* browser) {
  if (!browser) {
    return;
  }
  content::WebContents* active =
      browser->tab_strip_model()
          ? browser->tab_strip_model()->GetActiveWebContents()
          : nullptr;
  if (!active) {
    return;
  }
  auto it = ViewMap().find(active);
  if (it == ViewMap().end()) {
    return;
  }
  MoriBrowserView* view = it->second;
  if (!view) {
    return;
  }
  int identifier = view.browserIdentifier;
  dispatch_async(dispatch_get_main_queue(), ^{
    [MoriRoot focusTabWithBrowserIdentifier:identifier];
  });
}

bool HandleBrowserCommand(int command_id) {
  if (!g_mori_browser) {
    return false;  // UI not up — let Chrome's default command run
  }
  switch (command_id) {
    // --- Original six (File menu / Spaces) ---
    case IDC_NEW_TAB:              [MoriRoot newTab];           return true;
    case IDC_NEW_WINDOW:           [MoriRoot newWindow];        return true;
    case IDC_NEW_INCOGNITO_WINDOW: [MoriRoot newPrivateWindow]; return true;
    case IDC_RESTORE_TAB:          [MoriRoot reopenClosedTab];  return true;
    case IDC_FOCUS_LOCATION:       [MoriRoot focusOmnibox];     return true;
    case IDC_CLOSE_TAB:            [MoriRoot closeCurrentTab];  return true;

    // --- Find (Edit ▸ Find) ---
    case IDC_FIND:                 [MoriRoot toggleFindBar];    return true;
    case IDC_FIND_NEXT:            [MoriRoot findNext];         return true;
    case IDC_FIND_PREVIOUS:        [MoriRoot findPrevious];     return true;
    case IDC_FOCUS_SEARCH:         [MoriRoot focusOmnibox];     return true;

    // --- Navigation / reload / zoom (View, History) ---
    case IDC_BACK:                 [MoriRoot goBack];           return true;
    case IDC_FORWARD:              [MoriRoot goForward];        return true;
    case IDC_HOME:                 [MoriRoot goHome];           return true;
    case IDC_RELOAD:               [MoriRoot reload];           return true;
    case IDC_RELOAD_BYPASSING_CACHE:
    case IDC_RELOAD_CLEARING_CACHE: [MoriRoot forceReload];     return true;
    case IDC_STOP:                 [MoriRoot stop];             return true;
    case IDC_ZOOM_PLUS:            [MoriRoot zoomIn];           return true;
    case IDC_ZOOM_MINUS:           [MoriRoot zoomOut];          return true;
    case IDC_ZOOM_NORMAL:          [MoriRoot resetZoom];        return true;

    // --- Developer (View ▸ Developer) → Millie's DevTools ---
    case IDC_DEV_TOOLS:
    case IDC_DEV_TOOLS_INSPECT:
    case IDC_DEV_TOOLS_CONSOLE:    [MoriRoot toggleDevTools];   return true;

    // --- Print (File) ---
    case IDC_PRINT:
    case IDC_BASIC_PRINT:          [MoriRoot printPage];        return true;

    // --- Tab menu actions on the current tab ---
    case IDC_CYCLE_TO_NEXT_TAB:    [MoriRoot selectNextTab];     return true;
    case IDC_CYCLE_TO_PREV_TAB:    [MoriRoot selectPreviousTab]; return true;
    case IDC_DUPLICATE_TAB:
    case IDC_DUPLICATE_TARGET_TAB: [MoriRoot duplicateCurrentTab]; return true;
    case IDC_WINDOW_MUTE_SITE:
    case IDC_MUTE_TARGET_SITE:     [MoriRoot toggleMuteCurrentTab]; return true;
    case IDC_WINDOW_PIN_TAB:
    case IDC_PIN_TARGET_TAB:       [MoriRoot togglePinCurrentTab];  return true;
    case IDC_WINDOW_CLOSE_TABS_TO_RIGHT:
                                   [MoriRoot closeTabsToRightOfCurrent]; return true;
    case IDC_NEW_SPLIT_TAB:        [MoriRoot newSplit];          return true;

    default:                       return false;
  }
}

bool OpenExternalUrls(const std::vector<GURL>& urls) {
  std::vector<std::string> specs;
  for (const GURL& url : urls) {
    if (url.is_valid()) {
      specs.push_back(url.spec());
    }
  }
  if (specs.empty()) {
    return false;  // nothing usable — let Chrome's default path run
  }
  NSLog(@"MORI OpenExternalUrls n=%zu uiReady=%d", specs.size(),
        [MoriRoot uiReady] ? 1 : 0);
  // Route to the active Space's own tab creation (same path the omnibox and
  // window.open adoption use) instead of Chrome's OpenUrlsInBrowser, which
  // creates an unobserved Browser whose tab never becomes a Millie tab (the
  // "link click does nothing / just flashes" bug). Stash + flush so cold
  // launches (UI not up yet) work too.
  std::vector<std::string>& pending = PendingExternalUrls();
  pending.insert(pending.end(), specs.begin(), specs.end());
  dispatch_async(dispatch_get_main_queue(),
                 ^{ FlushPendingExternalUrls(/*attempts_left=*/50); });
  return true;  // Millie owns these; don't let Chrome open an unobserved window
}

bool HandleExternalProtocol(const GURL& url, bool has_user_gesture) {
  // App-scheme links — webex://, msteams://, zoommtg://, tel:, sms:, … — that
  // Chrome would route through LaunchURL below, which posts to a confirmation
  // dialog Millie's non-Views chrome never presents, so the link silently does
  // nothing from any surface (main tab, web panel, Peek, popup). Hand it to the
  // OS's default app instead. Gated on a real user gesture so a page can't
  // auto-launch apps; without a gesture we return false and Chrome's (inert)
  // default path runs — no regression.
  if (!has_user_gesture || !url.is_valid() || ![MoriRoot uiReady]) {
    return false;
  }
  const std::string_view scheme = url.scheme();
  // Web / internal / inert schemes never reach HandleExternalProtocol, but
  // guard so only genuine app-launch schemes are ever handed to the OS.
  static const char* const kNonExternal[] = {
      "http", "https", "file", "about", "chrome", "chrome-extension",
      "chrome-untrusted", "devtools", "blob", "data", "filesystem",
      "javascript", "view-source", "ftp", "ws", "wss", "mori", "millie"};
  for (const char* s : kNonExternal) {
    if (scheme == s) {
      return false;
    }
  }
  NSString* spec = base::SysUTF8ToNSString(url.spec());
  dispatch_async(dispatch_get_main_queue(), ^{
    [MoriRoot openExternalSchemeWithURL:spec];
  });
  return true;  // Millie launched it; don't run Chrome's inert dialog path
}

}  // namespace mori

// ---------------------------------------------------------------------------
// MoriBrowserView

// Resolve a Millie profile key to a Chromium Profile. Empty/"default" → the
// primary profile; "incognito" → the primary off-the-record (in-memory) profile
// shared by all private Spaces (no on-disk history/cookies/cache); any other key
// → a lazily-created persistent "Millie-<key>" profile.
static Profile* MoriProfileFromKey(const std::string& key) {
  if (!g_mori_browser) {
    return nullptr;
  }
  if (key.empty() || key == "default") {
    return g_mori_browser->GetProfile();
  }
  if (key == "incognito") {
    Profile* base_profile = g_mori_browser->GetProfile();
    return base_profile
               ? base_profile->GetPrimaryOTRProfile(/*create_if_needed=*/true)
               : nullptr;
  }
  ProfileManager* pm = g_browser_process->profile_manager();
  if (!pm) {
    return nullptr;
  }
  return pm->GetProfile(pm->user_data_dir().AppendASCII("Millie-" + key));
}

// Resolve the Browser whose (isolated) Profile should host a tab with the given
// Millie profile key. Empty/"default" → the primary Browser. Any other key gets
// a lazily-created headless Browser (never shown) over the resolved Profile —
// persistent for named profiles, off-the-record for "incognito".
static Browser* MoriBrowserForProfileKey(NSString* profileKey) {
  if (!g_mori_browser) {
    return nullptr;
  }
  std::string key = base::SysNSStringToUTF8(profileKey ?: @"");
  if (key.empty() || key == "default") {
    return g_mori_browser;
  }
  auto it = g_profile_browsers->find(key);
  if (it != g_profile_browsers->end()) {
    return it->second;
  }
  Profile* profile = MoriProfileFromKey(key);  // synchronous create/load
  if (!profile) {
    return g_mori_browser;
  }
  BrowserWindowInterface* browser_window = CreateBrowserWindow(
      BrowserWindowCreateParams(profile, /*from_user_gesture=*/true));
  Browser* browser =
      browser_window ? static_cast<Browser*>(browser_window) : nullptr;
  if (!browser) {
    return g_mori_browser;
  }
  // Intentionally never call browser->window()->Show(): this is a headless tab
  // container; its tabs' native views are reparented into the visible window.
  // Observe its tab strip so engine-created popups land as Millie tabs too.
  browser->tab_strip_model()->AddObserver(mori::MoriTabStripObserver());
  // Reflect this Space's downloads into DownloadStore too (not just default's).
  mori::EnsureDownloadObserverForProfile(profile);
  // Pre-grant auto-PiP for conferencing hosts on this isolated Space's profile
  // (incognito Spaces in particular need ALLOW, since "ask" reads as BLOCK).
  MoriSeedAutoPipContentSettings(profile);
  (*g_profile_browsers)[key] = browser;
  NSLog(@"MORI: isolated profile browser key=%s profile=%p browser=%p",
        key.c_str(), profile, browser);
  return browser;
}

// The TabStripModel that actually owns `wc` (isolated tabs live in a per-profile
// Browser, not the primary one). Falls back to the primary Browser.
static TabStripModel* MoriModelForContents(content::WebContents* wc) {
  if (wc) {
    if (Browser* b = MoriFindBrowserWithTab(wc)) {
      return b->tab_strip_model();
    }
  }
  return g_mori_browser ? g_mori_browser->tab_strip_model() : nullptr;
}

// The StoragePartition for a Millie profile key, loading the profile if needed
// (no Browser is created). Used by clear-data so each Profile's jar is reached.
static content::StoragePartition* MoriPartitionForProfileKey(NSString* profileKey) {
  if (!g_mori_browser) {
    return nullptr;
  }
  std::string key = base::SysNSStringToUTF8(profileKey ?: @"");
  Profile* profile = MoriProfileFromKey(key);
  return profile ? profile->GetDefaultStoragePartition() : nullptr;
}

namespace mori {

// The active Space's profile (where extension install/management operate).
Profile* ActiveProfile() {
  if (!g_mori_browser) {
    return nullptr;
  }
  Profile* profile = MoriProfileFromKey(*g_active_profile_key);
  return profile ? profile : g_mori_browser->GetProfile();
}

void SetActiveProfileKey(const std::string& key) {
  (*g_active_profile_key) = key.empty() ? "default" : key;
}

Profile* ProfileForKey(const std::string& key) {
  return MoriProfileFromKey(key);
}

// The Browser whose tab strip holds the active Space's tabs. focusBrowser()
// keeps each per-profile Browser's active tab in lockstep with the Millie
// selection, so this Browser's GetActiveWebContents() is the tab the user sees.
Browser* ActiveBrowser() {
  if (!g_mori_browser) {
    return nullptr;
  }
  if (g_active_profile_key->empty() || *g_active_profile_key == "default") {
    return g_mori_browser;
  }
  return MoriBrowserForProfileKey(
      base::SysUTF8ToNSString(*g_active_profile_key));
}

}  // namespace mori

@implementation MoriBrowserView {
  content::WebContents* _webContents;  // Owned by the TabStripModel.
  std::unique_ptr<mori::TabBridge> _bridge;
  NSString* _pendingURL;
  NSView* __strong _webView;
  double _zoomLevel;
  BOOL _webWindowVisible;
  BOOL _ignoresGlobalWebContentSuppression;
  BOOL _closeInitiatedLocally;  // -closeBrowser set this; engineWebContentsGone reads+clears it.
  int _browserIdentifier;
}

@synthesize navDelegate = _navDelegate;
@synthesize profileKey = _profileKey;
@synthesize currentURL = _currentURL;
@synthesize currentTitle = _currentTitle;
@synthesize isLoading = _isLoading;
@synthesize canGoBack = _canGoBack;
@synthesize canGoForward = _canGoForward;

- (instancetype)initWithURL:(NSString*)url {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _pendingURL = [url copy] ?: @"about:blank";
    _currentURL = [url copy] ?: @"";
    _currentTitle = @"";
    _webWindowVisible = YES;
    _browserIdentifier = g_next_browser_identifier++;
    [AllViews() addObject:self];
  }
  return self;
}

- (void)dealloc {
  [AllViews() removeObject:self];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self maybeCreateTab];
}

- (void)layout {
  [super layout];
  [self maybeCreateTab];
}

// Creates (or adopts) the engine tab once the view lives in a window — the
// same lazy contract as the CEF-backed implementation.
- (void)maybeCreateTab {
  if (_webContents || !self.window || NSIsEmptyRect(self.bounds) ||
      !g_mori_browser) {
    return;
  }

  GURL url(base::SysNSStringToUTF8(_pendingURL));
  if (!url.is_valid()) {
    url = GURL("about:blank");
  }

  // Which (isolated) profile should host this tab. Chrome's built-in WebUI
  // (chrome://extensions etc.) now follows the active Space's profile too, so a
  // Space's extension set is what its manage page shows (Arc per-profile model).
  Browser* targetBrowser = MoriBrowserForProfileKey(_profileKey);
  if (!targetBrowser) {
    return;
  }

  // Adopt an engine-created orphan (popup / window.open / chrome.tabs.create)
  // waiting at this URL *whose profile matches this tab's profile*. Matching by
  // profile keeps an isolated Space's popup in its own jar (and a default popup
  // out of one) and, crucially, preserves the live WebContents — so window.open
  // / OAuth popups keep their window.opener instead of being replaced by a fresh
  // navigation that drops the relationship.
  {
    Profile* wantProfile = targetBrowser->GetProfile();
    const base::TimeTicks now = base::TimeTicks::Now();
    // Drop orphans whose designated adopter never came. A real adopter (the
    // PostTask'd openNewTabWithURL for this popup) realizes within a moment, so
    // anything older is abandoned — and leaving it lets an unrelated tab that
    // realizes seconds/minutes later adopt it (the cross-tab "hijack": a stray
    // window.open / e-sign popup surfacing under, e.g., an n8n tab). Pruning
    // also keeps the map from growing without bound.
    for (auto it = OrphanMap().begin(); it != OrphanMap().end();) {
      if (now - it->second.stashed_at > kOrphanAdoptTTL) {
        it = OrphanMap().erase(it);
      } else {
        ++it;
      }
    }
    content::WebContents* adopted = nullptr;
    auto claimMatching = [&](const std::string& key) {
      auto range = OrphanMap().equal_range(key);
      for (auto it = range.first; it != range.second; ++it) {
        if (it->second.contents &&
            it->second.contents->GetBrowserContext() == wantProfile) {
          adopted = it->second.contents;
          OrphanMap().erase(it);
          return true;
        }
      }
      return false;
    };
    if (claimMatching(url.spec()) ||
        (url.spec() != "about:blank" && claimMatching("about:blank"))) {
      [self engineAttachWebContents:adopted];
      return;
    }
  }

  NavigateParams params(targetBrowser, url,
                        ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
  params.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
  params.window_action = NavigateParams::WindowAction::kNoAction;
  g_self_insert_in_progress = true;
  Navigate(&params);
  g_self_insert_in_progress = false;
  if (content::WebContents* wc = params.navigated_or_inserted_contents) {
    [self engineAttachWebContents:wc];
  }
}

- (void)engineAttachWebContents:(content::WebContents*)webContents {
  _webContents = webContents;
  // Delegate to the WebContents' own Browser (its profile). For default-profile
  // tabs this is the primary Browser (unchanged); for isolated tabs it's their
  // headless Browser, so window.open popups stay in the same Profile.
  if (Browser* owner = MoriFindBrowserWithTab(webContents)) {
    webContents->SetDelegate(BrowserWebContentsDelegate::From(owner));
  } else if (g_mori_browser) {
    webContents->SetDelegate(BrowserWebContentsDelegate::From(g_mori_browser));
  }
  ViewMap()[webContents] = self;
  _bridge = std::make_unique<mori::TabBridge>(webContents, self);

  // Ensure Chrome's AutoPictureInPictureTabHelper is attached so conferencing
  // apps (Meet/Zoom/Teams) that register the 'enterpictureinpicture' media
  // session action auto-open a document-PiP window when this tab is switched
  // away from. Tabs inserted into a real TabStripModel normally get this via
  // tabs::TabModel/TabHelpers::AttachTabHelpers, but attach defensively here —
  // this is Millie's single per-tab adoption chokepoint — and guard against a
  // double-create. The helper triggers off TabStripModel activation changes
  // (focusBrowser -> ActivateTabAt), which Millie drives on every tab switch.
  if (webContents &&
      !AutoPictureInPictureTabHelper::FromWebContents(webContents)) {
    AutoPictureInPictureTabHelper::CreateForWebContents(webContents);
  }

  NSView* webView = webContents->GetNativeView().GetNativeNSView();
  _webView = webView;
  webView.frame = self.bounds;
  webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:webView];
  [self applySuppressionState];
  // window.open() creates the popup's WebContents hidden+throttled; once we've
  // adopted it into a visible view, wake it so the page loads at full speed
  // instead of the background-tab crawl (the Peek's slow-first-paint fix).
  if (!self.isHidden && _webWindowVisible) {
    webContents->WasShown();
  }
  if (!self.isHidden && _webWindowVisible) {
    [self focusBrowser];
  }
}

- (void)engineWebContentsGone {
  // Distinguish an engine-side teardown (window.close(), renderer crash) from a
  // close Millie itself asked for via -closeBrowser. Only the former needs the
  // delegate to drop its tab/peek — a Millie-initiated close already removed it.
  const BOOL engineInitiated = !_closeInitiatedLocally;
  _closeInitiatedLocally = NO;
  if (_webContents) {
    ViewMap().erase(_webContents);
    _webContents = nullptr;
  }
  _bridge.reset();
  [_webView removeFromSuperview];
  _webView = nil;
  // During app quit / end-session, Chromium tears down every tab's WebContents
  // engine-initiated. Routing those teardowns back into the store would empty
  // the tab strip, make the store mint a fresh replacement new-tab, and then
  // overwrite session.json with that degenerate state (losing pins and the real
  // tabs) before prepareForTermination's authoritative save runs. Skip the
  // delegate entirely while shutting down: the store keeps its live tabs so the
  // termination save persists the true session. (browser_shutdown::
  // IsTryingToQuit() is set by CloseAllBrowsersAndQuit before CloseAllBrowsers;
  // HasShutdownStarted() covers the SIGTERM/end-session path.)
  if (browser_shutdown::IsTryingToQuit() ||
      browser_shutdown::HasShutdownStarted()) {
    return;
  }
  if (engineInitiated &&
      [_navDelegate respondsToSelector:@selector(browserViewDidCloseFromEngine:)]) {
    // Defer to the next runloop tick: we're on Chromium's WebContents-teardown
    // stack (TabBridge::WebContentsDestroyed), and the delegate will close a
    // tab / dismiss a peek — mutating the strip here would re-enter it. This
    // mirrors how peek()/closePeek() defer their own engine work.
    __weak MoriBrowserView* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      MoriBrowserView* strongSelf = weakSelf;
      if (!strongSelf) {
        return;
      }
      id<MoriBrowserViewDelegate> delegate = strongSelf.navDelegate;
      if ([delegate respondsToSelector:@selector(browserViewDidCloseFromEngine:)]) {
        [delegate browserViewDidCloseFromEngine:strongSelf];
      }
    });
  }
}

// MARK: engine state → delegate

- (void)engineSetTitle:(NSString*)title {
  _currentTitle = [title copy] ?: @"";
  if ([_navDelegate respondsToSelector:@selector(browserView:
                                           didChangeTitle:)]) {
    [_navDelegate browserView:self didChangeTitle:_currentTitle];
  }
}

- (void)engineSetURL:(NSString*)url {
  _currentURL = [url copy] ?: @"";
  if ([_navDelegate respondsToSelector:@selector(browserView:didChangeURL:)]) {
    [_navDelegate browserView:self didChangeURL:_currentURL];
  }
  if ([_navDelegate respondsToSelector:@selector(browserView:
                                           didCommitNavigationToURL:)]) {
    [_navDelegate browserView:self didCommitNavigationToURL:_currentURL];
  }
}

- (void)engineSetFaviconImage:(NSImage*)image iconURL:(NSString*)iconURL {
  if (iconURL.length &&
      [_navDelegate respondsToSelector:@selector(browserView:
                                           didChangeFaviconURLs:)]) {
    [_navDelegate browserView:self didChangeFaviconURLs:@[ iconURL ]];
  }
  if ([_navDelegate respondsToSelector:@selector(browserView:
                                           didLoadFaviconImage:)]) {
    [_navDelegate browserView:self didLoadFaviconImage:image];
  }
}

- (void)engineSetLoading:(BOOL)loading {
  const BOOL wasLoading = _isLoading;
  _isLoading = loading;
  [self engineNavStateChanged];
  if (!wasLoading && loading) {
    if ([_navDelegate respondsToSelector:@selector
                      (browserView:didStartNavigationToURL:isRedirect:
                                      userGesture:)]) {
      [_navDelegate browserView:self
          didStartNavigationToURL:_currentURL
                       isRedirect:NO
                      userGesture:NO];
    }
  } else if (wasLoading && !loading) {
    if ([_navDelegate respondsToSelector:@selector
                      (browserView:didFinishNavigationToURL:httpStatusCode:)]) {
      [_navDelegate browserView:self
          didFinishNavigationToURL:_currentURL
                    httpStatusCode:200];
    }
  }
}

- (void)engineNavStateChanged {
  if (_webContents) {
    _canGoBack = _webContents->GetController().CanGoBack();
    _canGoForward = _webContents->GetController().CanGoForward();
  }
  if ([_navDelegate respondsToSelector:@selector
                    (browserView:didChangeLoading:canGoBack:canGoForward:)]) {
    [_navDelegate browserView:self
             didChangeLoading:_isLoading
                    canGoBack:_canGoBack
                 canGoForward:_canGoForward];
  }
}

- (void)engineFindReplyOrdinal:(int)ordinal count:(int)count {
  if ([_navDelegate respondsToSelector:@selector
                    (browserView:didUpdateFindMatchOrdinal:ofMatches:)]) {
    [_navDelegate browserView:self
        didUpdateFindMatchOrdinal:ordinal
                        ofMatches:count];
  }
}

- (void)engineRequestsNewTabWithURL:(NSString*)url {
  if ([_navDelegate respondsToSelector:@selector(browserView:
                                           requestsNewTabWithURL:)]) {
    [_navDelegate browserView:self requestsNewTabWithURL:url];
  }
}

- (void)engineAudioStateChanged:(BOOL)audible {
  if ([_navDelegate respondsToSelector:@selector(browserView:
                                           didChangeAudioState:)]) {
    [_navDelegate browserView:self didChangeAudioState:audible];
  }
}

- (void)setAudioMuted:(BOOL)muted {
  if (_webContents) {
    _webContents->SetAudioMuted(muted);
  }
}

- (BOOL)isAudioMuted {
  return _webContents ? _webContents->IsAudioMuted() : NO;
}

// MARK: commands

- (void)loadURL:(NSString*)url {
  _pendingURL = [url copy];
  if (!_webContents) {
    [self maybeCreateTab];
    return;
  }
  GURL gurl(base::SysNSStringToUTF8(url));
  if (!gurl.is_valid()) {
    return;
  }
  content::NavigationController::LoadURLParams params(gurl);
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  _webContents->GetController().LoadURLWithParams(params);
}

- (void)goBack {
  if (_webContents && _webContents->GetController().CanGoBack()) {
    _webContents->GetController().GoBack();
  }
}

- (void)goForward {
  if (_webContents && _webContents->GetController().CanGoForward()) {
    _webContents->GetController().GoForward();
  }
}

- (void)reload {
  if (_webContents) {
    _webContents->GetController().Reload(content::ReloadType::NORMAL, false);
  }
}

- (void)reloadIgnoringCache {
  if (_webContents) {
    _webContents->GetController().Reload(content::ReloadType::BYPASSING_CACHE,
                                         false);
  }
}

- (void)stopLoading {
  if (_webContents) {
    _webContents->Stop();
  }
}

// MARK: zoom

- (void)zoomIn {
  [self adjustZoomBy:0.5];
}

- (void)zoomOut {
  [self adjustZoomBy:-0.5];
}

- (void)resetZoom {
  _zoomLevel = 0;
  [self applyZoom];
}

- (void)setZoomFactor:(double)factor {
  if (factor <= 0) {
    return;
  }
  _zoomLevel = std::log(factor) / std::log(1.2);
  [self applyZoom];
}

- (void)adjustZoomBy:(double)delta {
  _zoomLevel += delta;
  [self applyZoom];
}

- (void)applyZoom {
  if (_webContents) {
    content::HostZoomMap::SetZoomLevel(_webContents, _zoomLevel);
  }
}

// MARK: find in page (real FindTabHelper — highlights, tickmarks, ordinals)

- (void)findText:(NSString*)text forward:(BOOL)forward {
  if (!_webContents) {
    return;
  }
  auto* helper = find_in_page::FindTabHelper::FromWebContents(_webContents);
  if (!helper) {
    return;
  }
  helper->StartFinding(base::SysNSStringToUTF16(text), forward,
                       /*case_sensitive=*/false, /*find_match=*/true);
}

- (void)stopFinding:(BOOL)clearSelection {
  if (!_webContents) {
    return;
  }
  auto* helper = find_in_page::FindTabHelper::FromWebContents(_webContents);
  if (!helper) {
    return;
  }
  helper->StopFinding(clearSelection
                          ? find_in_page::SelectionAction::kClear
                          : find_in_page::SelectionAction::kKeep);
}

// MARK: devtools / print

- (void)showDevTools {
  if (_webContents) {
    DevToolsWindow::OpenDevToolsWindow(
        _webContents, DevToolsOpenedByAction::kUnknown);
  }
}

- (void)closeDevTools {
  if (_webContents) {
    if (DevToolsWindow::GetInstanceForInspectedWebContents(_webContents) &&
        g_mori_browser) {
      // Acts on the browser's active tab — Millie keeps that in lockstep with
      // its own selection (focusBrowser).
      DevToolsWindow::ToggleDevToolsWindow(g_mori_browser,
                                           DevToolsToggleAction::Toggle());
    }
  }
}

- (void)toggleDevTools {
  if (!_webContents) {
    return;
  }
  if (DevToolsWindow::GetInstanceForInspectedWebContents(_webContents)) {
    [self closeDevTools];
  } else {
    [self showDevTools];
  }
}

- (void)printPage {
  // TODO(mori): wire chrome printing (printing::StartPrint).
}

// MARK: scripting

- (BOOL)evaluateJavaScript:(NSString*)source
                   worldID:(int)worldID
                completion:(MoriJavaScriptResultHandler)completion {
  if (![NSThread isMainThread]) {
    NSString* sourceCopy = [source copy];
    MoriJavaScriptResultHandler handler = [completion copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![self evaluateJavaScript:sourceCopy worldID:worldID completion:handler]) {
        handler(nil, @"Browser unavailable");
      }
    });
    return YES;
  }
  if (!_webContents) {
    return NO;
  }
  content::RenderFrameHost* frame = _webContents->GetPrimaryMainFrame();
  if (!frame) {
    return NO;
  }
  MoriJavaScriptResultHandler handler = [completion copy];
  frame->ExecuteJavaScriptForTests(
      base::SysNSStringToUTF16(source),
      base::BindOnce(^(base::Value value) {
        handler(NSObjectFromValue(value), nil);
      }),
      worldID);
  return YES;
}

- (BOOL)evaluateJavaScript:(NSString*)source
                completion:(MoriJavaScriptResultHandler)completion {
  return [self evaluateJavaScript:source
                          worldID:content::ISOLATED_WORLD_ID_GLOBAL
                       completion:completion];
}

- (BOOL)evaluateMediaJavaScript:(NSString*)source
                      completion:(MoriJavaScriptResultHandler)completion {
  return [self evaluateJavaScript:source
                          worldID:kMoriMediaWorldId
                       completion:completion];
}

// MARK: image context-menu actions (native copy/save)

// Convert a window-space point (AppKit, bottom-left origin) into the render
// widget's viewport coordinates (top-left origin, DIP) that CopyImageAt /
// SaveImageAt expect. Returns NO if there's no live render view.
- (BOOL)viewportPointForWindowPoint:(NSPoint)windowPoint
                               outX:(int*)outX
                               outY:(int*)outY {
  content::RenderWidgetHostView* rv =
      _webContents ? _webContents->GetRenderWidgetHostView() : nullptr;
  NSView* nsview = rv ? rv->GetNativeView().GetNativeNSView() : nil;
  if (!nsview) {
    return NO;
  }
  NSPoint local = [nsview convertPoint:windowPoint fromView:nil];
  CGFloat y = nsview.isFlipped ? local.y : nsview.bounds.size.height - local.y;
  *outX = static_cast<int>(std::lround(local.x));
  *outY = static_cast<int>(std::lround(y));
  return YES;
}

- (BOOL)copyImageAtWindowPoint:(NSPoint)windowPoint {
  if (!_webContents) {
    return NO;
  }
  content::RenderFrameHost* frame = _webContents->GetPrimaryMainFrame();
  int x = 0, y = 0;
  if (!frame ||
      ![self viewportPointForWindowPoint:windowPoint outX:&x outY:&y]) {
    return NO;
  }
  // Copies the already-decoded bitmap — no network fetch, so cross-origin
  // (CORS-restricted) images copy fine.
  frame->CopyImageAt(x, y);
  return YES;
}

- (BOOL)inspectElementAtWindowPoint:(NSPoint)windowPoint {
  if (!_webContents) {
    return NO;
  }
  content::RenderFrameHost* frame = _webContents->GetPrimaryMainFrame();
  int x = 0, y = 0;
  if (!frame ||
      ![self viewportPointForWindowPoint:windowPoint outX:&x outY:&y]) {
    return NO;
  }
  // Opens DevTools (creating it if needed) and selects the element at the
  // click point — the same entry point as Chrome's "Inspect" context item.
  DevToolsWindow::InspectElement(frame, x, y);
  return YES;
}

- (BOOL)saveImageURL:(NSString*)url atWindowPoint:(NSPoint)windowPoint {
  if (!_webContents) {
    return NO;
  }
  content::RenderFrameHost* frame = _webContents->GetPrimaryMainFrame();
  if (!frame) {
    return NO;
  }
  GURL gurl(base::SysNSStringToUTF8(url ?: @""));
  // Canvas and large data-URL images have no fetchable URL; let the renderer
  // post back the download (mirrors Chromium's own RenderViewContextMenu).
  if (!gurl.is_valid() || gurl.SchemeIs("data")) {
    int x = 0, y = 0;
    if (![self viewportPointForWindowPoint:windowPoint outX:&x outY:&y]) {
      return NO;
    }
    frame->SaveImageAt(x, y);
    return YES;
  }
  // http(s)/blob/file images download by URL through Chromium's download UI,
  // using the frame's isolation info (correct referrer, cookies, etc.).
  _webContents->SaveFrame(gurl, content::Referrer(), frame);
  return YES;
}

// MARK: focus / visibility / lifetime

- (void)engineMaybeRefocus {
  if (!_webContents || self.isHidden || !_webWindowVisible || _webView.hidden ||
      ![MoriRoot shouldAutoFocusWebContent]) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self->_webContents || self.isHidden || !self->_webWindowVisible ||
        self->_webView.hidden || ![MoriRoot shouldAutoFocusWebContent]) {
      return;
    }
    NSWindow* window = self.window ?: self->_webView.window;
    // Don't cross-window steal focus. This fires from WebContentsObserver
    // callbacks (DidStopLoading / PrimaryPageChanged) on the main window's
    // tabs, which SPAs like Outlook trigger constantly in the background. If
    // the user is working in another window (e.g. a popup / compose window),
    // grabbing key here would yank them out mid-type. Only auto-refocus web
    // content when our own window is already key (or nothing is key).
    if (NSApp.keyWindow && NSApp.keyWindow != window) {
      return;
    }
    if (IsNativeTextInputFirstResponder(window.firstResponder)) {
      return;
    }
    [self focusBrowser];
  });
}

- (BOOL)ownsFirstResponder:(NSResponder*)responder {
  if (!_webContents || ![responder isKindOfClass:[NSView class]]) {
    return NO;
  }
  NSView* view = static_cast<NSView*>(responder);
  content::RenderWidgetHostView* renderView =
      _webContents->GetRenderWidgetHostView();
  NSView* rendererNativeView =
      renderView ? renderView->GetNativeView().GetNativeNSView() : nil;
  return (rendererNativeView && [view isDescendantOf:rendererNativeView]) ||
         [view isDescendantOf:self];
}

- (BOOL)canReceiveBrowserFocus {
  return _webContents && !self.isHidden && _webWindowVisible &&
         !_webView.hidden && self.window;
}

- (BOOL)focusRendererAndForwardKeyEventIfNeeded:(NSEvent*)event {
  if (event.type != NSEventTypeKeyDown || ![self canReceiveBrowserFocus]) {
    return NO;
  }
  NSEventModifierFlags modifiers =
      event.modifierFlags &
      (NSEventModifierFlagCommand | NSEventModifierFlagOption |
       NSEventModifierFlagControl);
  if (modifiers != 0) {
    return NO;
  }

  content::RenderWidgetHostView* renderView =
      _webContents->GetRenderWidgetHostView();
  NSView* rendererNativeView =
      renderView ? renderView->GetNativeView().GetNativeNSView() : nil;
  NSWindow* window = self.window ?: rendererNativeView.window ?: _webView.window;
  if (!window || (event.window && event.window != window) ||
      !rendererNativeView.window) {
    return NO;
  }
  if (IsNativeTextInputFirstResponder(window.firstResponder)) {
    return NO;
  }
  if (window.firstResponder == rendererNativeView) {
    return NO;
  }

  if (!window.isKeyWindow) {
    [window makeKeyWindow];
  }
  [window makeFirstResponder:rendererNativeView];
  if (renderView) {
    renderView->Focus();
  }
  _webContents->Focus();

  if (window.firstResponder != rendererNativeView) {
    return NO;
  }

  if ([rendererNativeView respondsToSelector:@selector(keyEvent:)]) {
    [rendererNativeView keyEvent:event];
  } else {
    [rendererNativeView keyDown:event];
  }
  return YES;
}

- (BOOL)ensureRendererFirstResponderForKeyEvent:(NSEvent*)event {
  if (![self canReceiveBrowserFocus]) {
    return NO;
  }
  NSEventModifierFlags modifiers =
      event.modifierFlags &
      (NSEventModifierFlagCommand | NSEventModifierFlagOption |
       NSEventModifierFlagControl);
  if (modifiers != 0) {
    return NO;
  }

  content::RenderWidgetHostView* renderView =
      _webContents->GetRenderWidgetHostView();
  NSView* rendererNativeView =
      renderView ? renderView->GetNativeView().GetNativeNSView() : nil;
  NSWindow* window = self.window ?: rendererNativeView.window ?: _webView.window;
  if (!window || (event.window && event.window != window) ||
      !rendererNativeView.window) {
    return NO;
  }
  if (IsNativeTextInputFirstResponder(window.firstResponder)) {
    return NO;
  }
  if (window.firstResponder == rendererNativeView) {
    if (renderView) {
      renderView->Focus();
    }
    _webContents->Focus();
    return YES;
  }

  if (!window.isKeyWindow) {
    [window makeKeyWindow];
  }
  [window makeFirstResponder:rendererNativeView];
  if (renderView) {
    renderView->Focus();
  }
  _webContents->Focus();
  return window.firstResponder == rendererNativeView;
}

- (BOOL)forwardRendererEditShortcutIfNeeded:(NSEvent*)event {
  if (event.type != NSEventTypeKeyDown || ![self canReceiveBrowserFocus]) {
    return NO;
  }

  NSEventModifierFlags modifiers =
      event.modifierFlags &
      (NSEventModifierFlagCommand | NSEventModifierFlagShift |
       NSEventModifierFlagOption | NSEventModifierFlagControl);
  const bool commandOnly = modifiers == NSEventModifierFlagCommand;
  const bool commandShift =
      modifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
  const unsigned short keyCode = event.keyCode;
  const bool standardEditShortcut =
      commandOnly &&
      (keyCode == 0 ||   // A
       keyCode == 6 ||   // Z
       keyCode == 7 ||   // X
       keyCode == 8 ||   // C
       keyCode == 9);    // V
  const bool redoShortcut = commandShift && keyCode == 6;  // Z
  if (!standardEditShortcut && !redoShortcut) {
    return NO;
  }

  content::RenderWidgetHostView* renderView =
      _webContents->GetRenderWidgetHostView();
  NSView* rendererNativeView =
      renderView ? renderView->GetNativeView().GetNativeNSView() : nil;
  NSWindow* window = self.window ?: rendererNativeView.window ?: _webView.window;
  if (!window || (event.window && event.window != window) ||
      !rendererNativeView.window) {
    return NO;
  }
  if (IsNativeTextInputFirstResponder(window.firstResponder)) {
    return NO;
  }
  // Undo/redo go straight to the web contents. The old route (make the renderer
  // first responder, then sendAction undo: down the responder chain) silently
  // dropped ⌘Z whenever any step of that focus dance failed. WebContents::Undo
  // acts on the focused frame's editable, which is exactly what ⌘Z should do.
  if ((commandOnly && keyCode == 6) || redoShortcut) {
    if (!window.isKeyWindow) {
      [window makeKeyWindow];
    }
    if (commandOnly) {
      _webContents->Undo();
    } else {
      _webContents->Redo();
    }
    return YES;
  }
  if (!window.isKeyWindow) {
    [window makeKeyWindow];
  }
  [window makeFirstResponder:rendererNativeView];
  if (renderView) {
    renderView->Focus();
  }
  _webContents->Focus();
  if (window.firstResponder != rendererNativeView) {
    return NO;
  }

  SEL action = nil;
  if (commandOnly) {
    switch (keyCode) {
      case 0:
        action = @selector(selectAll:);
        break;
      case 6:
        action = @selector(undo:);
        break;
      case 7:
        action = @selector(cut:);
        break;
      case 8:
        action = @selector(copy:);
        break;
      case 9:
        action = @selector(paste:);
        break;
      default:
        break;
    }
  } else if (redoShortcut) {
    action = @selector(redo:);
  }
  if (action &&
      [NSApp sendAction:action to:rendererNativeView from:self]) {
    return YES;
  }
  if (action && [NSApp sendAction:action to:nil from:self]) {
    return YES;
  }
  return [rendererNativeView performKeyEquivalent:event];
}

- (BOOL)containsEventLocation:(NSEvent*)event {
  if (![self canReceiveBrowserFocus]) {
    return NO;
  }
  NSWindow* window = self.window ?: _webView.window;
  if (!window || event.window != window) {
    return NO;
  }
  NSPoint localPoint = [self convertPoint:event.locationInWindow fromView:nil];
  return NSPointInRect(localPoint, self.bounds);
}

- (void)focusBrowser {
  if (!_webContents || !g_mori_browser) {
    return;
  }
  // Keep chrome's "active tab" (what chrome.tabs and extension actions see)
  // in lockstep with Millie's selection.
  TabStripModel* model = MoriModelForContents(_webContents);
  const int index = model ? model->GetIndexOfWebContents(_webContents)
                          : TabStripModel::kNoTab;
  if (index != TabStripModel::kNoTab && model->active_index() != index) {
    model->ActivateTabAt(index);
  }
  content::RenderWidgetHostView* renderView =
      _webContents->GetRenderWidgetHostView();
  NSView* rendererNativeView =
      renderView ? renderView->GetNativeView().GetNativeNSView() : nil;
  NSWindow* window = self.window ?: rendererNativeView.window ?: _webView.window;
  // Never steal key focus from another window. focusBrowser runs from several
  // triggers (auto-refocus after background loads, tab attach, in-window
  // clicks). If a different window currently holds key — e.g. a popup / compose
  // window the user is typing in — grabbing key here would yank them out. Only
  // take key + first responder when our own window already holds key, or when
  // nothing does. SPAs like Outlook fire background loads constantly, so this
  // guard is what keeps a popup usable.
  if (NSApp.keyWindow && NSApp.keyWindow != window) {
    return;
  }
  if (window && !window.isKeyWindow) {
    [window makeKeyWindow];
  }
  if (rendererNativeView.window) {
    [rendererNativeView.window makeFirstResponder:rendererNativeView];
  }
  if (renderView) {
    renderView->Focus();
  }
  _webContents->Focus();
}

- (void)takeKeyboardFocusPreservingPage {
  if (!_webContents || !g_mori_browser) {
    return;
  }
  // Keep chrome's "active tab" in lockstep with Millie's selection.
  TabStripModel* model = MoriModelForContents(_webContents);
  const int index = model ? model->GetIndexOfWebContents(_webContents)
                          : TabStripModel::kNoTab;
  if (index != TabStripModel::kNoTab && model->active_index() != index) {
    model->ActivateTabAt(index);
  }
  content::RenderWidgetHostView* renderView =
      _webContents->GetRenderWidgetHostView();
  NSView* rendererNativeView =
      renderView ? renderView->GetNativeView().GetNativeNSView() : nil;
  NSWindow* window = self.window ?: rendererNativeView.window ?: _webView.window;
  // Route the keyboard here so ⌘C/⌘V/typing reach this web content:
  //  1. key window + AppKit first responder (so the NSView gets the events), and
  //  2. renderView->Focus() — focus the RenderWidgetHost at the Blink level.
  //     This is REQUIRED: Chromium only executes editing commands (copy/paste)
  //     on a content-focused widget, so without it ⌘C/⌘V silently no-op even
  //     though the NSView is first responder (confirmed: clipboard changeCount
  //     never moved on ⌘C). Focusing the *widget* restores the page's existing
  //     focused element, so the field the user just clicked keeps its caret.
  //  We still DON'T call _webContents->Focus(): that can reset focus to the top
  //  frame and blur a clicked iframe field (Outlook/Gmail compose & search).
  // No key-steal guard: this is an explicit user-initiated handback.
  if (window && !window.isKeyWindow) {
    [window makeKeyWindow];
  }
  if (rendererNativeView.window) {
    [rendererNativeView.window makeFirstResponder:rendererNativeView];
  }
  if (renderView) {
    renderView->Focus();
  }
}

// Deterministic clipboard commands routed straight to THIS tab's WebContents.
// content::WebContents::Copy/Cut/Paste/SelectAll act on the WebContents' own
// focused frame regardless of which NSWindow is key or what holds AppKit first
// responder — so ⌘C/⌘V work even when a panel (web panel child window or the
// SwiftUI AI composer) has stolen OS focus. This is the reliable path; the
// focus-reassert dance in routePanelClick is only needed for *typing*.
- (void)copySelection {
  if (_webContents) _webContents->Copy();
}
- (void)cutSelection {
  if (_webContents) _webContents->Cut();
}
- (void)pasteClipboard {
  if (_webContents) _webContents->Paste();
}
- (void)selectAllContent {
  if (_webContents) _webContents->SelectAll();
}

// Web-content undo/redo. Chromium's RenderWidgetHostViewCocoa implements
// copy:/cut:/paste:/selectAll: but NOT undo:/redo:, so ⌘Z / ⇧⌘Z did nothing in
// web text fields (the Edit-menu selectors reached the web view and were
// dropped). MoriBrowserView sits above the web view in the responder chain, so
// these fire when web content is focused and the RWHVCocoa didn't handle them —
// while a focused omnibox / find bar / AI-composer field editor still undoes
// natively (its field editor handles undo: first, before the chain reaches us).
- (void)undo:(id)sender {
  if (_webContents) _webContents->Undo();
}
- (void)redo:(id)sender {
  if (_webContents) _webContents->Redo();
}

// Main-menu command targets. These are reached the same way Undo/Redo above are:
// the menu items are set to target=nil with one of these selectors, so AppKit
// resolves them through the responder chain to this view (the proven path — it's
// how the Edit menu works in Millie), validates via -validateUserInterfaceItem:
// below, and dispatches here. Each forwards to the matching MoriRoot action,
// which operates on the store's selected tab. mori-prefixed so they can't
// collide with any AppKit/Chromium responder selector.
- (void)moriReload:(id)sender { [MoriRoot reload]; }
- (void)moriForceReload:(id)sender { [MoriRoot forceReload]; }
- (void)moriStop:(id)sender { [MoriRoot stop]; }
- (void)moriGoHome:(id)sender { [MoriRoot goHome]; }
- (void)moriGoBack:(id)sender { [MoriRoot goBack]; }
- (void)moriGoForward:(id)sender { [MoriRoot goForward]; }
- (void)moriZoomIn:(id)sender { [MoriRoot zoomIn]; }
- (void)moriZoomOut:(id)sender { [MoriRoot zoomOut]; }
- (void)moriResetZoom:(id)sender { [MoriRoot resetZoom]; }
- (void)moriToggleFindBar:(id)sender { [MoriRoot toggleFindBar]; }
- (void)moriFindNext:(id)sender { [MoriRoot findNext]; }
- (void)moriFindPrevious:(id)sender { [MoriRoot findPrevious]; }
- (void)moriFocusOmnibox:(id)sender { [MoriRoot focusOmnibox]; }
- (void)moriToggleDevTools:(id)sender { [MoriRoot toggleDevTools]; }
- (void)moriPrintPage:(id)sender { [MoriRoot printPage]; }
- (void)moriSelectNextTab:(id)sender { [MoriRoot selectNextTab]; }
- (void)moriSelectPreviousTab:(id)sender { [MoriRoot selectPreviousTab]; }
- (void)moriDuplicateTab:(id)sender { [MoriRoot duplicateCurrentTab]; }
- (void)moriTogglePinTab:(id)sender { [MoriRoot togglePinCurrentTab]; }
- (void)moriToggleMuteTab:(id)sender { [MoriRoot toggleMuteCurrentTab]; }
- (void)moriCloseTabsToRight:(id)sender { [MoriRoot closeTabsToRightOfCurrent]; }
- (void)moriNewSplit:(id)sender { [MoriRoot newSplit]; }
- (void)moriCloseTab:(id)sender { [MoriRoot closeCurrentTab]; }

// Chrome's main-menu browser commands (Reload, Back/Forward, Zoom, Print, Close
// Tab, Duplicate/Pin/Mute Tab, …) are plain target=nil `commandDispatch:` items
// tagged with their IDC. In Chrome they dispatch through the browser window's
// command controller — which Millie's plain NSWindow doesn't have, so AppKit
// greyed them out. Rather than rewrite Chrome's menu items (it rebuilds them on
// activation and CHECKs their tags), we handle `commandDispatch:` right here:
// MoriBrowserView is already in the key window's responder chain (that's how the
// Edit menu's undo:/redo: reach us), RWHVCocoa doesn't implement
// commandDispatch:, and AppController (the app delegate) is further down the
// chain. So the menu resolves these to us. We service the commands Millie owns
// and forward everything else (New Tab, New Window, …) to AppController so its
// app-level commands keep working exactly as before.
- (void)commandDispatch:(id)sender {
  if (MoriRunBrowserCommand([sender tag])) {
    return;
  }
  id del = NSApp.delegate;  // forward app-level commands to AppController
  if ([del respondsToSelector:@selector(commandDispatch:)]) {
    [del commandDispatch:sender];
  }
}

- (void)commandDispatchUsingKeyModifiers:(id)sender {
  if (MoriRunBrowserCommand([sender tag])) {
    return;
  }
  id del = NSApp.delegate;
  if ([del respondsToSelector:@selector(commandDispatchUsingKeyModifiers:)]) {
    [del commandDispatchUsingKeyModifiers:sender];
  }
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  SEL action = [item action];
  if (action == @selector(commandDispatch:) ||
      action == @selector(commandDispatchUsingKeyModifiers:)) {
    if (MoriSelectorForCommand([item tag])) {
      return YES;  // a command Millie services — always available
    }
    // Not ours: let AppController decide (so New Tab/New Window/… stay correct).
    id del = NSApp.delegate;
    if ([del respondsToSelector:@selector(validateUserInterfaceItem:)]) {
      return [del validateUserInterfaceItem:item];
    }
    return NO;
  }
  if (action == @selector(undo:) || action == @selector(redo:)) {
    return _webContents != nullptr;
  }
  return [self respondsToSelector:action];
}

- (void)setTabPinned:(BOOL)pinned {
  if (!_webContents || !g_mori_browser) {
    return;
  }
  TabStripModel* model = MoriModelForContents(_webContents);
  const int index = model ? model->GetIndexOfWebContents(_webContents)
                          : TabStripModel::kNoTab;
  if (index != TabStripModel::kNoTab && model->IsTabPinned(index) != pinned) {
    model->SetTabPinned(index, pinned);
  }
}

- (int)browserIdentifier {
  return _browserIdentifier;
}

static BOOL MoriIsAllowedMediaAction(NSString* action) {
  static NSSet<NSString*>* allowed;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    allowed = [NSSet setWithObjects:@"play", @"pause", @"toggle", @"seek",
                                   @"seekBy", @"mute", @"pip", @"pipEnter",
                                   @"pipExit", nil];
  });
  return [allowed containsObject:action];
}

static NSString* MoriMediaCommandScript(NSString* action, double value) {
  std::string script = base::StringPrintf(R"JS(
(() => {
  const action = "%s";
  const value = %.17g;
  const closestElement = (target, selector) => {
    for (let n = target; n; n = n.parentNode || (n.host || null)) {
      if (n.nodeType === 1 && n.matches && n.matches(selector)) return n;
    }
    return null;
  };
  const hasAudibleTrack = (el) =>
    !el.muted && (typeof el.volume !== 'number' || el.volume > 0);
  const isYouTubePreview = (el) => {
    const host = location.hostname.replace(/^www\./, '');
    if (host !== 'youtube.com' && host !== 'm.youtube.com') return false;
    if (!el.muted) return false;
    return !closestElement(el, '#movie_player, ytd-player, #shorts-player');
  };
  const eligible = (el) => {
    if (!el || isYouTubePreview(el)) return false;
    // These markers are written by Millie's media agent in the same isolated
    // world; page scripts cannot spoof them with main-world expandos.
    if (el.__moriMediaEligible || el.__moriMediaUserSelected) return true;
    return !el.paused && hasAudibleTrack(el);
  };
  const pick = () => {
    const els = Array.from(document.querySelectorAll('video,audio')).filter((m) =>
      (m.currentSrc || m.src) && eligible(m));
    if (!els.length) return null;
    els.sort((a, b) => {
      const ap = a.paused ? 0 : 1;
      const bp = b.paused ? 0 : 1;
      if (ap !== bp) return bp - ap;
      const aa = (a.videoWidth || 0) * (a.videoHeight || 0);
      const ba = (b.videoWidth || 0) * (b.videoHeight || 0);
      return ba - aa;
    });
    return els[0];
  };
  const pickVideo = () => {
    const el = pick();
    return el && el.tagName === 'VIDEO' ? el : null;
  };
  // Remember if the user dismissed PiP so auto-PiP (fired on tab switch) does
  // not pop it back up. Flags live on window and reset naturally on navigation.
  const armDismissWatch = (el) => {
    if (!el || el.__milliePipWatch) return;
    el.__milliePipWatch = true;
    el.addEventListener('leavepictureinpicture', () => {
      // A leave we did not initiate ourselves means the user closed the PiP
      // window — suppress auto-PiP until they ask for it again.
      if (!window.__milliePipProgrammaticExit) window.__milliePipAutoOff = true;
    });
  };
  const pipEnter = (auto) => {
    try {
      if (auto && window.__milliePipAutoOff) return;
      if (document.pictureInPictureElement) return;
      const el = pickVideo();
      if (el && el.requestPictureInPicture) {
        armDismissWatch(el);
        el.requestPictureInPicture().catch(() => {});
      }
    } catch (e) {}
  };
  const pipExit = () => {
    try {
      if (document.pictureInPictureElement) {
        window.__milliePipProgrammaticExit = true;
        document.exitPictureInPicture().catch(() => {});
        setTimeout(() => { window.__milliePipProgrammaticExit = false; }, 500);
      }
    } catch (e) {}
  };
  if (action === 'pip') {
    // Manual toggle from the media player: closing keeps it closed across tab
    // switches; opening clears the suppression because the user wants PiP.
    if (document.pictureInPictureElement) {
      window.__milliePipAutoOff = true;
      pipExit();
    } else {
      window.__milliePipAutoOff = false;
      pipEnter(false);
    }
    return;
  }
  if (action === 'pipEnter') { pipEnter(true); return; }
  if (action === 'pipExit') {
    // Fired when the tab is brought back to the foreground. Returning to the
    // tab resets the auto-PiP cycle: a dismissal (X or back-to-tab, both of
    // which read as a non-programmatic leave) only suppresses re-popping while
    // the user STAYS away — the next tab-away should PiP again.
    window.__milliePipAutoOff = false;
    pipExit();
    return;
  }
  const el = pick();
  if (!el) return;
  switch (action) {
    case 'play':
      if (el.play) el.play();
      break;
    case 'pause':
      if (el.pause) el.pause();
      break;
    case 'toggle':
      el.paused ? (el.play && el.play()) : (el.pause && el.pause());
      break;
    case 'seek':
      el.currentTime = value;
      break;
    case 'seekBy':
      el.currentTime = Math.max(0, (el.currentTime || 0) + value);
      break;
    case 'mute':
      el.muted = !el.muted;
      break;
  }
})()
)JS",
      base::SysNSStringToUTF8(action).c_str(), value);
  return base::SysUTF8ToNSString(script);
}

// Run fixed media-command JavaScript with a synthetic user activation so gated
// media APIs succeed without calling any page-overwritable function.
- (void)runMediaScriptWithUserGesture:(NSString*)source {
  if (!_webContents) {
    return;
  }
  content::RenderFrameHost* frame = _webContents->GetPrimaryMainFrame();
  if (!frame) {
    return;
  }
  frame->ExecuteJavaScriptWithUserGestureForTests(
      base::SysNSStringToUTF16(source), base::BindOnce(^(base::Value) {}),
      kMoriMediaWorldId);
}

- (void)sendMediaCommand:(NSString*)action value:(double)value {
  if (![NSThread isMainThread]) {
    NSString* actionCopy = [action copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self sendMediaCommand:actionCopy value:value];
    });
    return;
  }
  if (action.length == 0) {
    return;
  }
  if (!MoriIsAllowedMediaAction(action)) {
    return;
  }
  [self runMediaScriptWithUserGesture:MoriMediaCommandScript(action, value)];
}

- (void)setPageHidden:(BOOL)hidden {
  if (!_webContents) {
    return;
  }
  if (hidden) {
    _webContents->WasHidden();
    // Pop a playing video out to PiP as the tab goes to the background. The
    // synthetic user gesture is what lets this clear the activation gate, so
    // no Chromium auto-PiP feature flag is required.
    if (g_mori_auto_pip) {
      [self runMediaScriptWithUserGesture:MoriMediaCommandScript(@"pipEnter", 0)];
    }
  } else {
    _webContents->WasShown();
    // Returning to the tab brings the video back inline.
    [self runMediaScriptWithUserGesture:MoriMediaCommandScript(@"pipExit", 0)];
  }
}

- (void)kickCompositor {
  if (!_webContents) {
    return;
  }
  _webContents->WasShown();
  if (content::RenderWidgetHostView* rwhv =
          _webContents->GetRenderWidgetHostView()) {
    if (content::RenderWidgetHost* rwh = rwhv->GetRenderWidgetHost()) {
      // Re-sync size/visibility → renderer produces a fresh frame. No key focus
      // required, so it works when the peek was opened from another app.
      rwh->SynchronizeVisualProperties();
    }
  }
}

- (void)setWebWindowVisible:(BOOL)visible {
  _webWindowVisible = visible;
  [self applySuppressionState];
}

- (void)setIgnoresGlobalWebContentSuppression:(BOOL)ignores {
  _ignoresGlobalWebContentSuppression = ignores;
  [self applySuppressionState];
}

- (void)applySuppressionState {
  const BOOL suppressed =
      g_web_content_suppressed && !_ignoresGlobalWebContentSuppression;
  _webView.hidden = !_webWindowVisible || suppressed;
}

- (void)applyAutoPiP:(BOOL)enabled {
  g_mori_auto_pip = enabled;
}

+ (void)setAutoPiPEnabled:(BOOL)enabled {
  g_mori_auto_pip = enabled;
}

+ (void)setAdBlockerEnabled:(BOOL)enabled {
  mori::SetAdBlockEnabled(enabled);
}

+ (void)setAdBlockerAllowedHosts:(NSArray<NSString*>*)hosts {
  std::vector<std::string> list;
  list.reserve(hosts.count);
  for (NSString* host in hosts) {
    const char* utf8 = host.UTF8String;
    if (utf8 && *utf8) {
      list.emplace_back(utf8);
    }
  }
  mori::SetAdBlockAllowedHosts(std::move(list));
}

+ (BOOL)cancelDownloadWithID:(uint32_t)downloadID {
  content::DownloadManager* manager = mori::MoriDownloadManager();
  if (!manager) {
    return NO;
  }
  if (download::DownloadItem* item = manager->GetDownload(downloadID)) {
    item->Cancel(/*from_user=*/true);
    return YES;
  }
  return NO;
}

+ (void)setWebContentSuppressed:(BOOL)suppressed {
  g_web_content_suppressed = suppressed;
  for (MoriBrowserView* view in [AllViews() copy]) {
    [view applySuppressionState];
  }
}

- (void)closeBrowser {
  if (!_webContents || !g_mori_browser) {
    return;
  }
  TabStripModel* model = MoriModelForContents(_webContents);
  const int index = model ? model->GetIndexOfWebContents(_webContents)
                          : TabStripModel::kNoTab;
  if (index != TabStripModel::kNoTab) {
    // Mark this teardown as Millie-initiated so engineWebContentsGone doesn't
    // report it back to the delegate as an engine-side close (which would try
    // to close the tab a second time).
    _closeInitiatedLocally = YES;
    model->CloseWebContentsAt(index, TabCloseTypes::CLOSE_USER_GESTURE |
                                         TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  }
}

@end

// ---------------------------------------------------------------------------
// MoriPrivacy

@implementation MoriPrivacy

+ (content::StoragePartition*)defaultPartition {
  if (!g_mori_browser) {
    return nullptr;
  }
  return g_mori_browser->GetProfile()->GetDefaultStoragePartition();
}

+ (void)warmupSpareRenderer {
  if (Profile* profile = mori::ActiveProfile()) {
    content::SpareRenderProcessHostManager::Get().WarmupSpare(profile);
  }
}

+ (void)clearCookies {
  if (content::StoragePartition* partition = [self defaultPartition]) {
    partition->GetCookieManagerForBrowserProcess()->DeleteCookies(
        network::mojom::CookieDeletionFilter::New(), base::DoNothing());
  }
}

+ (void)clearCache {
  if (content::StoragePartition* partition = [self defaultPartition]) {
    partition->GetNetworkContext()->ClearHttpCache(
        base::Time(), base::Time::Max(), nullptr, base::DoNothing());
  }
}

+ (void)flushCookies {
  // Flush the default jar plus every loaded isolated profile so no Profile's
  // session/persistent cookies are lost on an abrupt quit.
  if (content::StoragePartition* partition = [self defaultPartition]) {
    partition->GetCookieManagerForBrowserProcess()->FlushCookieStore(
        base::DoNothing());
  }
  for (const auto& entry : *g_profile_browsers) {
    if (entry.second) {
      entry.second->GetProfile()
          ->GetDefaultStoragePartition()
          ->GetCookieManagerForBrowserProcess()
          ->FlushCookieStore(base::DoNothing());
    }
  }
}

+ (void)clearCookiesForProfileKeys:(NSArray<NSString*>*)keys {
  for (NSString* key in keys) {
    if (content::StoragePartition* partition =
            MoriPartitionForProfileKey(key)) {
      partition->GetCookieManagerForBrowserProcess()->DeleteCookies(
          network::mojom::CookieDeletionFilter::New(), base::DoNothing());
    }
  }
}

+ (void)clearCacheForProfileKeys:(NSArray<NSString*>*)keys {
  for (NSString* key in keys) {
    if (content::StoragePartition* partition =
            MoriPartitionForProfileKey(key)) {
      partition->GetNetworkContext()->ClearHttpCache(
          base::Time(), base::Time::Max(), nullptr, base::DoNothing());
    }
  }
}

@end

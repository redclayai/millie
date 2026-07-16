// Millie "Import from your old browser" — reads another Chromium-family
// browser's on-disk profile (Chrome, Brave, Edge, Arc, Vivaldi, Chromium) and
// brings its data into Millie. Detection + the plaintext stores (bookmarks
// JSON, history SQLite) are cheap file reads; the encrypted stores (passwords,
// cookies, autofill/payment) are decrypted with the SOURCE browser's macOS
// "Safe Storage" Keychain key (AES-128-CBC, PBKDF2 "saltysalt"/1003), so the
// first encrypted import triggers a one-time Keychain approval prompt for that
// browser's item — exactly like Arc's importer.
//
// Bookmarks + history land in Millie's own Swift stores (BookmarkStore/
// HistoryStore); passwords/cookies/autofill are written straight into the
// target Millie Profile's Chromium services. All methods run on the main
// (browser UI) thread.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MoriImport : NSObject

/// Chromium-family browsers found on disk. Each dictionary contains:
///   id        (NSString)  stable key, e.g. "chrome", "brave", "arc"
///   name      (NSString)  display name, e.g. "Google Chrome"
///   dataDir   (NSString)  the User Data directory holding the profiles
///   profiles  (NSArray<NSDictionary*>) each {dir (NSString), name (NSString)}
/// Only browsers with an existing User Data dir and at least one profile are
/// returned, sorted by name.
+ (NSArray<NSDictionary*>*)detectBrowsers NS_SWIFT_NAME(detectBrowsers());

/// Read up to `limit` most-recent history entries from a source profile.
/// The live DB is copied first so a running source browser doesn't block the
/// read. Each dictionary: url, title (NSString); visitCount (NSNumber);
/// lastVisited (NSDate). Empty on any failure.
+ (NSArray<NSDictionary*>*)readHistoryForDataDir:(NSString*)dataDir
                                      profileDir:(NSString*)profileDir
                                           limit:(NSInteger)limit
    NS_SWIFT_NAME(readHistory(dataDir:profileDir:limit:));

/// Read the source profile's bookmarks as a flat list of {url, title}. Reads
/// the Bookmarks JSON directly (no decryption needed).
+ (NSArray<NSDictionary*>*)readBookmarksForDataDir:(NSString*)dataDir
                                        profileDir:(NSString*)profileDir
    NS_SWIFT_NAME(readBookmarks(dataDir:profileDir:));

/// Import the encrypted/Chromium-owned stores into the target Millie Profile
/// (key = "default" or a Profile uuid). `browserId` selects the Keychain item;
/// `types` is any of "passwords", "cookies", "autocomplete", "addresses",
/// "cards". Returns a dictionary of per-type NSNumber counts under those keys
/// plus "errors" (NSArray<NSString*>). Blocking; may prompt for Keychain
/// access the first time an encrypted store is read.
+ (NSDictionary*)importEncryptedFromDataDir:(NSString*)dataDir
                                 profileDir:(NSString*)profileDir
                                  browserId:(NSString*)browserId
                                      types:(NSArray<NSString*>*)types
                             intoProfileKey:(NSString*)profileKey
    NS_SWIFT_NAME(importEncrypted(dataDir:profileDir:browserId:types:intoProfileKey:));

@end

NS_ASSUME_NONNULL_END

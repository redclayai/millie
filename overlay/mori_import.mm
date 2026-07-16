// Millie "Import from your old browser". See mori_import.h.

#import "chrome/browser/ui/mori/mori_import.h"

#import <CommonCrypto/CommonCrypto.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/mori/mori_chrome_hooks.h"
#include "components/autofill/core/browser/data_manager/payments/payments_data_manager.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/field_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "url/gurl.h"

namespace {

// Reuse an allowlisted sql metrics tag (sql/histograms.xml); the tag is only a
// UMA label, and the importer conceptually belongs with FirefoxImporter.
constexpr sql::Database::Tag kImportTag{"FirefoxImporter"};

// A Chromium-family browser Millie can import from.
struct SourceBrowser {
  const char* id;
  const char* name;
  // Relative to ~/Library/Application Support.
  const char* relative_data_dir;
  // macOS Keychain generic-password service holding the AES key.
  const char* keychain_service;
};

const SourceBrowser kBrowsers[] = {
    {"chrome", "Google Chrome", "Google/Chrome", "Chrome Safe Storage"},
    {"brave", "Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"},
    {"edge", "Microsoft Edge", "Microsoft Edge",
     "Microsoft Edge Safe Storage"},
    {"arc", "Arc", "Arc/User Data", "Arc Safe Storage"},
    {"vivaldi", "Vivaldi", "Vivaldi", "Vivaldi Safe Storage"},
    {"chromium", "Chromium", "Chromium", "Chromium Safe Storage"},
};

const SourceBrowser* FindBrowser(const std::string& id) {
  for (const auto& b : kBrowsers) {
    if (id == b.id) {
      return &b;
    }
  }
  return nullptr;
}

base::FilePath AppSupportDir() {
  NSString* dir = NSSearchPathForDirectoriesInDomains(
                      NSApplicationSupportDirectory, NSUserDomainMask, YES)
                      .firstObject;
  return base::FilePath(base::SysNSStringToUTF8(dir ?: @""));
}

// Chrome timestamps are microseconds since the Windows epoch (1601-01-01).
base::Time TimeFromChrome(int64_t micros) {
  if (micros <= 0) {
    return base::Time();
  }
  return base::Time::FromDeltaSinceWindowsEpoch(base::Microseconds(micros));
}

NSDate* NSDateFromChrome(int64_t micros) {
  if (micros <= 0) {
    return [NSDate dateWithTimeIntervalSince1970:0];
  }
  // Windows-epoch micros → Unix seconds.
  double unix_seconds = (static_cast<double>(micros) - 11644473600000000.0) /
                        1000000.0;
  return [NSDate dateWithTimeIntervalSince1970:unix_seconds];
}

// Copy a possibly-live SQLite file to a temp path so a running source browser
// doesn't block the read. Returns an empty path on failure.
base::FilePath CopyToTemp(const base::FilePath& src) {
  if (!base::PathExists(src)) {
    return base::FilePath();
  }
  base::FilePath tmp;
  if (!base::CreateTemporaryFile(&tmp)) {
    return base::FilePath();
  }
  if (!base::CopyFile(src, tmp)) {
    base::DeleteFile(tmp);
    return base::FilePath();
  }
  // Bring the WAL sidecar along if present so recent writes are visible.
  base::FilePath wal_src(src.value() + "-wal");
  if (base::PathExists(wal_src)) {
    base::CopyFile(wal_src, base::FilePath(tmp.value() + "-wal"));
  }
  base::FilePath shm_src(src.value() + "-shm");
  if (base::PathExists(shm_src)) {
    base::CopyFile(shm_src, base::FilePath(tmp.value() + "-shm"));
  }
  return tmp;
}

// ---- macOS Safe Storage decryption --------------------------------------

// The source browser's AES key, derived from its Keychain "Safe Storage"
// secret. Empty if the item is absent or the user denied Keychain access.
std::string DeriveAesKey(const char* keychain_service) {
  @autoreleasepool {
    NSDictionary* query = @{
      (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService :
          [NSString stringWithUTF8String:keychain_service],
      (__bridge id)kSecReturnData : @YES,
      (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = nullptr;
    OSStatus status =
        SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
      if (result) {
        CFRelease(result);
      }
      return std::string();
    }
    NSData* secret = (__bridge_transfer NSData*)result;
    uint8_t key[16] = {0};
    const char* salt = "saltysalt";
    if (CCKeyDerivationPBKDF(
            kCCPBKDF2, static_cast<const char*>(secret.bytes), secret.length,
            reinterpret_cast<const uint8_t*>(salt), 9, kCCPRFHmacAlgSHA1, 1003,
            key, sizeof(key)) != kCCSuccess) {
      return std::string();
    }
    return std::string(reinterpret_cast<char*>(key), sizeof(key));
  }
}

// Decrypt a Chromium "v10" AES-128-CBC blob. Returns the plaintext bytes, or
// the input verbatim when it carries no version prefix (legacy plaintext).
std::string DecryptValue(const std::string& aes_key,
                         const std::string& ciphertext) {
  if (ciphertext.size() < 3 || ciphertext.compare(0, 3, "v10") != 0) {
    return ciphertext;  // Not encrypted (or unknown scheme): pass through.
  }
  if (aes_key.size() != 16) {
    return std::string();
  }
  std::string body = ciphertext.substr(3);
  if (body.empty() || (body.size() % 16) != 0) {
    return std::string();
  }
  uint8_t iv[16];
  memset(iv, ' ', sizeof(iv));  // Chromium uses 16 spaces as the IV.
  std::string out(body.size() + 16, '\0');
  size_t moved = 0;
  CCCryptorStatus st = CCCrypt(
      kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding, aes_key.data(),
      aes_key.size(), iv, body.data(), body.size(), out.data(), out.size(),
      &moved);
  if (st != kCCSuccess) {
    return std::string();
  }
  out.resize(moved);
  return out;
}

// Recent macOS Chrome prepends a 32-byte SHA-256(host_key) to the decrypted
// cookie value; strip it when present so the stored value is clean.
std::string StripCookieDomainHash(std::string plaintext,
                                  const std::string& host_key) {
  if (plaintext.size() < 32) {
    return plaintext;
  }
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(host_key.data(), static_cast<CC_LONG>(host_key.size()), digest);
  if (memcmp(plaintext.data(), digest, 32) == 0) {
    return plaintext.substr(32);
  }
  return plaintext;
}

// ---- Per-store importers -------------------------------------------------

int ImportPasswords(const base::FilePath& profile_dir,
                    const std::string& aes_key,
                    Profile* target,
                    std::vector<std::string>* errors) {
  base::FilePath tmp = CopyToTemp(profile_dir.Append("Login Data"));
  if (tmp.empty()) {
    return 0;
  }
  scoped_refptr<password_manager::PasswordStoreInterface> store =
      ProfilePasswordStoreFactory::GetForProfile(
          target, ServiceAccessType::EXPLICIT_ACCESS);
  int count = 0;
  {
    sql::Database db(kImportTag);
    if (db.Open(tmp)) {
      sql::Statement s(db.GetUniqueStatement(
          "SELECT origin_url, username_value, password_value, signon_realm, "
          "date_created, blacklisted_by_user FROM logins"));
      while (store && s.is_valid() && s.Step()) {
        std::string origin = s.ColumnString(0);
        std::string enc = s.ColumnString(2);
        std::string password = DecryptValue(aes_key, enc);
        bool blocked = s.ColumnInt(5) != 0;
        if (password.empty() && !blocked) {
          continue;  // couldn't decrypt and it's not a "never save" entry
        }
        password_manager::StoredCredential cred;
        cred.scheme = password_manager::PasswordForm::Scheme::kHtml;
        cred.signon_realm = s.ColumnString(3);
        cred.url = GURL(origin);
        cred.username_value = base::UTF8ToUTF16(s.ColumnString(1));
        cred.password_value = base::UTF8ToUTF16(password);
        cred.date_created = TimeFromChrome(s.ColumnInt64(4));
        cred.blocked_by_user = blocked;
        cred.in_store = password_manager::PasswordForm::Store::kProfileStore;
        store->AddLogin(std::move(cred));
        ++count;
      }
    } else {
      errors->push_back("passwords: could not open Login Data");
    }
  }
  base::DeleteFile(tmp);
  return count;
}

int ImportCookies(const base::FilePath& profile_dir,
                  const std::string& aes_key,
                  Profile* target,
                  std::vector<std::string>* errors) {
  base::FilePath tmp = CopyToTemp(profile_dir.Append("Cookies"));
  if (tmp.empty()) {
    // Some browsers keep it under Network/.
    tmp = CopyToTemp(profile_dir.Append("Network").Append("Cookies"));
  }
  if (tmp.empty()) {
    return 0;
  }
  content::StoragePartition* partition = target->GetDefaultStoragePartition();
  network::mojom::CookieManager* cm =
      partition ? partition->GetCookieManagerForBrowserProcess() : nullptr;
  int count = 0;
  {
    sql::Database db(kImportTag);
    if (db.Open(tmp) && cm) {
      sql::Statement s(db.GetUniqueStatement(
          "SELECT host_key, name, encrypted_value, path, expires_utc, "
          "is_secure, is_httponly, samesite, creation_utc, source_port, "
          "source_scheme FROM cookies"));
      net::CookieOptions options = net::CookieOptions::MakeAllInclusive();
      while (s.is_valid() && s.Step()) {
        std::string host = s.ColumnString(0);
        std::string value =
            StripCookieDomainHash(DecryptValue(aes_key, s.ColumnString(2)),
                                  host);
        if (value.empty()) {
          continue;
        }
        base::Time creation = TimeFromChrome(s.ColumnInt64(8));
        base::Time expires = TimeFromChrome(s.ColumnInt64(4));
        bool secure = s.ColumnInt(5) != 0;
        std::string clean_host =
            host.empty() || host[0] != '.' ? host : host.substr(1);
        GURL source_url((secure ? "https://" : "http://") + clean_host + "/");
        std::unique_ptr<net::CanonicalCookie> cookie =
            net::CanonicalCookie::FromStorage(
                s.ColumnString(1), value, host, s.ColumnString(3), creation,
                expires, /*last_access=*/creation, /*last_update=*/creation,
                secure, s.ColumnInt(6) != 0,
                static_cast<net::CookieSameSite>(s.ColumnInt(7)),
                net::COOKIE_PRIORITY_DEFAULT,
                /*partition_key=*/std::nullopt,
                static_cast<net::CookieSourceScheme>(s.ColumnInt(10)),
                s.ColumnInt(9), net::CookieSourceType::kOther,
                net::CanonicalCookieFromStorageCallSite::kCookieManager);
        if (!cookie) {
          continue;
        }
        cm->SetCanonicalCookie(*cookie, source_url, options, base::DoNothing());
        ++count;
      }
    } else if (!cm) {
      errors->push_back("cookies: no cookie manager for target profile");
    } else {
      errors->push_back("cookies: could not open Cookies DB");
    }
  }
  base::DeleteFile(tmp);
  return count;
}

int ImportCards(const base::FilePath& profile_dir,
                const std::string& aes_key,
                Profile* target,
                std::vector<std::string>* errors) {
  base::FilePath tmp = CopyToTemp(profile_dir.Append("Web Data"));
  if (tmp.empty()) {
    return 0;
  }
  autofill::PersonalDataManager* pdm =
      autofill::PersonalDataManagerFactory::GetForBrowserContext(target);
  int count = 0;
  {
    sql::Database db(kImportTag);
    if (db.Open(tmp) && pdm) {
      sql::Statement s(db.GetUniqueStatement(
          "SELECT name_on_card, expiration_month, expiration_year, "
          "card_number_encrypted FROM credit_cards"));
      while (s.is_valid() && s.Step()) {
        std::string number = DecryptValue(aes_key, s.ColumnString(3));
        if (number.empty()) {
          continue;
        }
        autofill::CreditCard card(
            base::Uuid::GenerateRandomV4().AsLowercaseString(),
            "https://millie.import/");
        card.SetRawInfo(autofill::CREDIT_CARD_NAME_FULL,
                        base::UTF8ToUTF16(s.ColumnString(0)));
        int month = s.ColumnInt(1);
        int year = s.ColumnInt(2);
        if (month > 0) {
          card.SetExpirationMonth(month);
        }
        if (year > 0) {
          card.SetExpirationYear(year);
        }
        card.SetNumber(base::UTF8ToUTF16(number));
        pdm->payments_data_manager().AddCreditCard(card);
        ++count;
      }
    } else if (!pdm) {
      errors->push_back("cards: no personal data manager for target profile");
    } else {
      errors->push_back("cards: could not open Web Data DB");
    }
  }
  base::DeleteFile(tmp);
  return count;
}

// Recursively flatten a Bookmarks JSON node into {url,title} dictionaries.
void FlattenBookmarkNode(const base::DictValue& node, NSMutableArray* out) {
  const std::string* type = node.FindString("type");
  if (type && *type == "url") {
    const std::string* url = node.FindString("url");
    const std::string* name = node.FindString("name");
    if (url && !url->empty()) {
      [out addObject:@{
        @"url" : base::SysUTF8ToNSString(*url),
        @"title" : base::SysUTF8ToNSString(name ? *name : *url),
      }];
    }
    return;
  }
  const base::ListValue* children = node.FindList("children");
  if (children) {
    for (const base::Value& child : *children) {
      if (child.is_dict()) {
        FlattenBookmarkNode(child.GetDict(), out);
      }
    }
  }
}

}  // namespace

@implementation MoriImport

+ (NSArray<NSDictionary*>*)detectBrowsers {
  base::FilePath app_support = AppSupportDir();
  NSMutableArray* result = [NSMutableArray array];
  for (const auto& b : kBrowsers) {
    base::FilePath data_dir = app_support.AppendASCII(b.relative_data_dir);
    if (!base::PathExists(data_dir)) {
      continue;
    }
    // Enumerate profiles from Local State's info cache; fall back to "Default".
    NSMutableArray* profiles = [NSMutableArray array];
    base::FilePath local_state = data_dir.Append("Local State");
    std::string json;
    if (base::ReadFileToString(local_state, &json)) {
      std::optional<base::DictValue> parsed =
          base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
      if (parsed) {
        const base::DictValue* cache =
            parsed->FindDictByDottedPath("profile.info_cache");
        if (cache) {
          for (const auto [dir, info] : *cache) {
            if (!info.is_dict()) {
              continue;
            }
            if (!base::PathExists(data_dir.AppendASCII(dir))) {
              continue;
            }
            const std::string* name = info.GetDict().FindString("name");
            [profiles addObject:@{
              @"dir" : base::SysUTF8ToNSString(dir),
              @"name" : base::SysUTF8ToNSString(name && !name->empty()
                                                    ? *name
                                                    : dir),
            }];
          }
        }
      }
    }
    if (profiles.count == 0 &&
        base::PathExists(data_dir.Append("Default"))) {
      [profiles addObject:@{@"dir" : @"Default", @"name" : @"Default"}];
    }
    if (profiles.count == 0) {
      continue;
    }
    [result addObject:@{
      @"id" : [NSString stringWithUTF8String:b.id],
      @"name" : [NSString stringWithUTF8String:b.name],
      @"dataDir" : base::SysUTF8ToNSString(data_dir.value()),
      @"profiles" : profiles,
    }];
  }
  [result sortUsingComparator:^NSComparisonResult(NSDictionary* a,
                                                  NSDictionary* b) {
    return [a[@"name"] compare:b[@"name"]];
  }];
  return result;
}

+ (NSArray<NSDictionary*>*)readHistoryForDataDir:(NSString*)dataDir
                                      profileDir:(NSString*)profileDir
                                           limit:(NSInteger)limit {
  base::FilePath dir = base::FilePath(base::SysNSStringToUTF8(dataDir))
                           .Append(base::SysNSStringToUTF8(profileDir));
  base::FilePath tmp = CopyToTemp(dir.Append("History"));
  if (tmp.empty()) {
    return @[];
  }
  NSMutableArray* out = [NSMutableArray array];
  {
    sql::Database db(kImportTag);
    if (db.Open(tmp)) {
      sql::Statement s(db.GetUniqueStatement(
          "SELECT url, title, visit_count, last_visit_time FROM urls "
          "WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT ?"));
      s.BindInt64(0, limit > 0 ? limit : 5000);
      while (s.is_valid() && s.Step()) {
        [out addObject:@{
          @"url" : base::SysUTF8ToNSString(s.ColumnString(0)),
          @"title" : base::SysUTF8ToNSString(s.ColumnString(1)),
          @"visitCount" : @(s.ColumnInt(2)),
          @"lastVisited" : NSDateFromChrome(s.ColumnInt64(3)),
        }];
      }
    }
  }
  base::DeleteFile(tmp);
  return out;
}

+ (NSArray<NSDictionary*>*)readBookmarksForDataDir:(NSString*)dataDir
                                        profileDir:(NSString*)profileDir {
  base::FilePath dir = base::FilePath(base::SysNSStringToUTF8(dataDir))
                           .Append(base::SysNSStringToUTF8(profileDir));
  std::string json;
  if (!base::ReadFileToString(dir.Append("Bookmarks"), &json)) {
    return @[];
  }
  std::optional<base::DictValue> parsed =
      base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!parsed) {
    return @[];
  }
  const base::DictValue* roots = parsed->FindDict("roots");
  if (!roots) {
    return @[];
  }
  NSMutableArray* out = [NSMutableArray array];
  for (const auto [key, value] : *roots) {
    if (value.is_dict()) {
      FlattenBookmarkNode(value.GetDict(), out);
    }
  }
  return out;
}

+ (NSDictionary*)importEncryptedFromDataDir:(NSString*)dataDir
                                 profileDir:(NSString*)profileDir
                                  browserId:(NSString*)browserId
                                      types:(NSArray<NSString*>*)types
                             intoProfileKey:(NSString*)profileKey {
  std::string id = base::SysNSStringToUTF8(browserId);
  const SourceBrowser* browser = FindBrowser(id);
  Profile* target = mori::ProfileForKey(base::SysNSStringToUTF8(profileKey));
  std::vector<std::string> errors;
  int passwords = 0, cookies = 0, cards = 0;

  if (!browser) {
    errors.push_back("unknown browser id");
  } else if (!target) {
    errors.push_back("target profile unavailable");
  } else {
    base::FilePath profile_dir =
        base::FilePath(base::SysNSStringToUTF8(dataDir))
            .Append(base::SysNSStringToUTF8(profileDir));
    std::string aes_key = DeriveAesKey(browser->keychain_service);
    bool need_key = [types containsObject:@"passwords"] ||
                    [types containsObject:@"cookies"] ||
                    [types containsObject:@"cards"];
    if (need_key && aes_key.empty()) {
      errors.push_back(
          "Keychain access to the source browser's Safe Storage was denied "
          "or unavailable — encrypted data could not be decrypted.");
    } else {
      if ([types containsObject:@"passwords"]) {
        passwords = ImportPasswords(profile_dir, aes_key, target, &errors);
      }
      if ([types containsObject:@"cookies"]) {
        cookies = ImportCookies(profile_dir, aes_key, target, &errors);
      }
      if ([types containsObject:@"cards"]) {
        cards = ImportCards(profile_dir, aes_key, target, &errors);
      }
    }
  }

  NSMutableArray* nserrors = [NSMutableArray array];
  for (const auto& e : errors) {
    [nserrors addObject:base::SysUTF8ToNSString(e)];
  }
  NSLog(@"MORI import: browser=%s passwords=%d cookies=%d cards=%d errors=%lu",
        id.c_str(), passwords, cookies, cards,
        (unsigned long)nserrors.count);
  return @{
    @"passwords" : @(passwords),
    @"cookies" : @(cookies),
    @"cards" : @(cards),
    @"errors" : nserrors,
  };
}

@end

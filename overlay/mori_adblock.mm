// Millie built-in ad/tracker blocker. See mori_adblock.h.

#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "chrome/browser/ui/mori/mori_adblock.h"
#include "crypto/sha2.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/net_errors.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "url/gurl.h"

namespace mori {
namespace {

// -1 = not yet set by the toggle (fall back to the persisted default);
// 0/1 = explicit value from +[MoriBrowserView setAdBlockerEnabled:].
std::atomic<int> g_enabled{-1};
std::atomic<uint64_t> g_blocked_count{0};
// Coalesces the per-block UI notification so a page blocking hundreds of
// requests posts at most one notification per main-queue turn.
std::atomic<bool> g_notify_pending{false};

// First 8 bytes of SHA-256(host), big-endian — identical to the Python builder
// (struct.pack(">Q", sha256(host).digest()[:8])).
uint64_t HostHash(std::string_view host) {
  std::string digest = crypto::SHA256HashString(host);
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i) {
    v = (v << 8) | static_cast<uint8_t>(digest[i]);
  }
  return v;
}

// The bundled sorted prefix table. Loaded once, lazily, then read-only.
class AdHostSet {
 public:
  static AdHostSet& Get() {
    static base::NoDestructor<AdHostSet> instance;
    return *instance;
  }

  bool Contains(uint64_t h) const {
    return std::binary_search(prefixes_.begin(), prefixes_.end(), h);
  }
  bool loaded() const { return !prefixes_.empty(); }

 private:
  friend class base::NoDestructor<AdHostSet>;
  AdHostSet() { Load(); }

  void Load() {
    @autoreleasepool {
      NSString* path = [[NSBundle mainBundle] pathForResource:@"adhosts"
                                                       ofType:@"bin"];
      if (!path) {
        return;
      }
      NSData* data = [NSData dataWithContentsOfFile:path];
      if (!data || data.length < 8) {
        return;
      }
      const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
      if (std::memcmp(bytes, "MAB1", 4) != 0) {
        return;
      }
      uint32_t count = static_cast<uint32_t>(bytes[4]) |
                       (static_cast<uint32_t>(bytes[5]) << 8) |
                       (static_cast<uint32_t>(bytes[6]) << 16) |
                       (static_cast<uint32_t>(bytes[7]) << 24);  // uint32 LE
      if (count == 0 || data.length < 8u + static_cast<uint64_t>(count) * 8u) {
        return;
      }
      prefixes_.reserve(count);
      const uint8_t* p = bytes + 8;
      for (uint32_t i = 0; i < count; ++i, p += 8) {
        uint64_t v = 0;
        for (int b = 0; b < 8; ++b) {
          v = (v << 8) | p[b];  // uint64 BE
        }
        prefixes_.push_back(v);
      }
      NSLog(@"MILLIE_ADBLOCK loaded %u host prefixes", count);
    }
  }

  std::vector<uint64_t> prefixes_;
};

// Normalize a GURL host the same way the builder does: strip a trailing dot and
// a leading "www." (GURL host is already lowercased).
std::string NormalizeHost(std::string_view host_view) {
  std::string host(host_view);
  if (!host.empty() && host.back() == '.') {
    host.pop_back();
  }
  if (host.rfind("www.", 0) == 0) {
    host = host.substr(4);
  }
  return host;
}

// The per-site allowlist ("Don't block ads on this site"). Lock-guarded:
// replaced wholesale from the Swift store on the main thread while lookups run
// on whichever sequence dispatches the proxy factory's mojo calls.
struct AdAllowlist {
  base::Lock lock;
  std::set<std::string> hosts;
  bool loaded = false;
};

AdAllowlist& Allowlist() {
  static base::NoDestructor<AdAllowlist> instance;
  return *instance;
}

// Seeds the allowlist from the persisted defaults array the Swift store writes
// (same lazy-fallback pattern as AdBlockEnabled: requests can arrive before
// AdBlockStore pushes). Caller holds the lock.
void LoadAllowlistFromDefaultsLocked(AdAllowlist& allowlist) {
  @autoreleasepool {
    NSArray* saved = [[NSUserDefaults standardUserDefaults]
        arrayForKey:@"mori.adblockAllowlist"];
    for (id entry in saved) {
      if (![entry isKindOfClass:[NSString class]]) {
        continue;
      }
      const char* utf8 = [(NSString*)entry UTF8String];
      if (utf8 && *utf8) {
        allowlist.hosts.insert(NormalizeHost(utf8));
      }
    }
  }
  allowlist.loaded = true;
}

void PostBlockedNotification() {
  if (g_notify_pending.exchange(true, std::memory_order_relaxed)) {
    return;  // a post is already queued; this block folds into it.
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    g_notify_pending.store(false, std::memory_order_relaxed);
    NSDictionary* info = @{
      @"count" : @(g_blocked_count.load(std::memory_order_relaxed))
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MoriAdBlocked"
                                                        object:nil
                                                      userInfo:info];
  });
}

// A URLLoaderFactory proxy: cancels ad/tracker subresource requests before they
// reach the network, forwards everything else to the terminal factory. Lifetime
// is self-managed (destroys itself when all proxy receivers and the target
// disconnect), mirroring Chrome's own proxying factories.
class MoriAdblockURLLoaderFactory : public network::mojom::URLLoaderFactory {
 public:
  MoriAdblockURLLoaderFactory(const MoriAdblockURLLoaderFactory&) = delete;
  MoriAdblockURLLoaderFactory& operator=(const MoriAdblockURLLoaderFactory&) =
      delete;

  static void Install(network::URLLoaderFactoryBuilder& factory_builder,
                      std::string first_party_host) {
    auto [receiver, target] = factory_builder.Append();
    new MoriAdblockURLLoaderFactory(std::move(receiver), std::move(target),
                                    std::move(first_party_host));
  }

  // network::mojom::URLLoaderFactory:
  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation)
      override {
    // This proxy is only installed on subresource factories
    // (kDocumentSubResource/kWorkerSubResource), so every request here is a
    // subresource — a main-frame/subframe navigation uses a kNavigation factory
    // and never reaches us. (Do NOT guard on is_outermost_main_frame: that flag
    // is true for any request originating in the top frame, including its
    // subresources, so it would suppress all blocking.)
    // The allowlist check runs after the blocklist hit so the common case (an
    // unlisted host) never takes the allowlist lock.
    if (AdBlockEnabled() && AdBlockShouldBlock(request.url) &&
        !AdBlockFirstPartyAllowed(first_party_host_)) {
      g_blocked_count.fetch_add(1, std::memory_order_relaxed);
      PostBlockedNotification();
      // Complete the request as blocked; never open a URLLoader. The queued
      // OnComplete is delivered before the client pipe closes.
      mojo::Remote<network::mojom::URLLoaderClient> client_remote(
          std::move(client));
      client_remote->OnComplete(
          network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
      return;
    }
    target_factory_->CreateLoaderAndStart(
        std::move(loader_receiver), request_id, options, request,
        std::move(client), traffic_annotation);
  }

  void Clone(mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver)
      override {
    proxy_receivers_.Add(this, std::move(receiver));
  }

 private:
  MoriAdblockURLLoaderFactory(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target_factory,
      std::string first_party_host)
      : first_party_host_(std::move(first_party_host)) {
    target_factory_.Bind(std::move(target_factory));
    target_factory_.set_disconnect_handler(base::BindOnce(
        &MoriAdblockURLLoaderFactory::OnTargetDisconnect,
        base::Unretained(this)));
    proxy_receivers_.Add(this, std::move(receiver));
    proxy_receivers_.set_disconnect_handler(base::BindRepeating(
        &MoriAdblockURLLoaderFactory::OnProxyDisconnect,
        base::Unretained(this)));
  }

  ~MoriAdblockURLLoaderFactory() override = default;

  void OnTargetDisconnect() { delete this; }
  void OnProxyDisconnect() {
    if (proxy_receivers_.empty()) {
      delete this;
    }
  }

  mojo::ReceiverSet<network::mojom::URLLoaderFactory> proxy_receivers_;
  mojo::Remote<network::mojom::URLLoaderFactory> target_factory_;
  // Host of the top-frame origin this factory serves (empty when unknown or
  // opaque), matched against the per-site allowlist.
  const std::string first_party_host_;
};

}  // namespace

void SetAdBlockEnabled(bool enabled) {
  g_enabled.store(enabled ? 1 : 0, std::memory_order_relaxed);
  NSLog(@"MILLIE_ADBLOCK setEnabled=%d", enabled ? 1 : 0);
}

bool AdBlockEnabled() {
  int e = g_enabled.load(std::memory_order_relaxed);
  if (e >= 0) {
    return e != 0;
  }
  // The toggle hasn't applied yet — fall back to the same persisted pref the
  // Swift setting writes (default on), and cache it.
  bool def = true;
  @autoreleasepool {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"mori.blockAds"];
    if (v != nil) {
      def = [v boolValue];
    }
  }
  int expected = -1;
  g_enabled.compare_exchange_strong(expected, def ? 1 : 0,
                                    std::memory_order_relaxed);
  return g_enabled.load(std::memory_order_relaxed) != 0;
}

uint64_t AdBlockBlockedCount() {
  return g_blocked_count.load(std::memory_order_relaxed);
}

void SetAdBlockAllowedHosts(std::vector<std::string> hosts) {
  AdAllowlist& allowlist = Allowlist();
  base::AutoLock scoped(allowlist.lock);
  allowlist.hosts.clear();
  for (const std::string& host : hosts) {
    std::string normalized = NormalizeHost(host);
    if (!normalized.empty()) {
      allowlist.hosts.insert(std::move(normalized));
    }
  }
  allowlist.loaded = true;
  NSLog(@"MILLIE_ADBLOCK allowlist n=%zu", allowlist.hosts.size());
}

bool AdBlockFirstPartyAllowed(const std::string& first_party_host) {
  if (first_party_host.empty()) {
    return false;
  }
  AdAllowlist& allowlist = Allowlist();
  base::AutoLock scoped(allowlist.lock);
  if (!allowlist.loaded) {
    LoadAllowlistFromDefaultsLocked(allowlist);
  }
  return allowlist.hosts.count(NormalizeHost(first_party_host)) > 0;
}

bool AdBlockShouldBlock(const GURL& url) {
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return false;
  }
  const AdHostSet& set = AdHostSet::Get();
  if (!set.loaded()) {
    return false;
  }
  std::string host = NormalizeHost(url.host());
  // Walk the host and its parent domains down to the two-label root:
  // ads.track.evil.com → ads.track.evil.com, track.evil.com, evil.com.
  std::string_view h(host);
  for (;;) {
    if (set.Contains(HostHash(h))) {
      return true;
    }
    size_t dot = h.find('.');
    if (dot == std::string_view::npos) {
      break;
    }
    std::string_view rest = h.substr(dot + 1);
    if (rest.find('.') == std::string_view::npos) {
      break;  // fewer than two labels remain
    }
    h = rest;
  }
  return false;
}

void MaybeProxyAdblock(network::URLLoaderFactoryBuilder& factory_builder,
                       bool is_subresource,
                       const std::string& first_party_host) {
  if (!is_subresource || !AdBlockEnabled()) {
    return;
  }
  if (!AdHostSet::Get().loaded()) {
    return;  // list failed to load — don't interpose a useless proxy.
  }
  // Install even for allowlisted sites: the allowlist is consulted per-request
  // so removing a site from it takes effect on reload without waiting for a
  // fresh factory (worker factories outlive documents).
  MoriAdblockURLLoaderFactory::Install(factory_builder, first_party_host);
}

}  // namespace mori

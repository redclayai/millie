// Millie built-in ad/tracker blocker — host-based, fully local.
//
// Loads a bundled sorted table of 64-bit SHA-256 host-hash prefixes
// (adhosts.bin, built by build_adblock_hosts.py from Block List Project +
// Peter Lowe's feeds) and cancels subresource requests whose host — or any
// parent domain — is listed. No per-request network calls; the check is a
// binary search over an in-memory table, matching Millie's ThreatStore model.
//
// Interception is a browser-side proxying URLLoaderFactory (see
// MaybeProxyAdblock), inserted from ChromeContentBrowserClient::
// WillCreateURLLoaderFactory for document/worker subresource factories — the
// only hook that sees renderer-initiated subresources, which is what ads are.
// Only this header is included by the one Chromium file we patch.

#ifndef CHROME_BROWSER_UI_MORI_MORI_ADBLOCK_H_
#define CHROME_BROWSER_UI_MORI_MORI_ADBLOCK_H_

#include <cstdint>

class GURL;
namespace network {
class URLLoaderFactoryBuilder;
}

namespace mori {

// Process-wide enable flag, driven by the "Block ads" setting via
// +[MoriBrowserView setAdBlockerEnabled:]. Until that fires, AdBlockEnabled()
// falls back to the persisted `mori.blockAds` default (on), so blocking is
// active from the first request regardless of UI-init timing.
void SetAdBlockEnabled(bool enabled);
bool AdBlockEnabled();

// True when the URL's host (or a parent domain, down to the two-label root) is
// on the bundled ad/tracker blocklist. http/https only.
bool AdBlockShouldBlock(const GURL& url);

// Total subresource requests cancelled this session (for the Settings readout).
uint64_t AdBlockBlockedCount();

// Inserts the ad-block proxying URLLoaderFactory into `factory_builder` when ad
// blocking is enabled and this is a subresource factory. No-op otherwise.
// Called from ChromeContentBrowserClient::WillCreateURLLoaderFactory.
void MaybeProxyAdblock(network::URLLoaderFactoryBuilder& factory_builder,
                       bool is_subresource);

}  // namespace mori

#endif  // CHROME_BROWSER_UI_MORI_MORI_ADBLOCK_H_

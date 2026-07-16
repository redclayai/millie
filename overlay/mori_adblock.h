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
#include <string>
#include <vector>

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

// Replaces the per-site allowlist ("Don't block ads on this site"), driven by
// AdBlockStore.swift via +[MoriBrowserView setAdBlockerAllowedHosts:]. Until
// that fires, the first lookup falls back to the same persisted
// `mori.adblockAllowlist` defaults array the Swift store writes. Matching is
// exact against the normalized top-frame host — the toggle grants the page the
// user was on, not its whole domain tree.
void SetAdBlockAllowedHosts(std::vector<std::string> hosts);

// True when the request's first-party (top-frame) host is on the allowlist.
bool AdBlockFirstPartyAllowed(const std::string& first_party_host);

// Inserts the ad-block proxying URLLoaderFactory into `factory_builder` when ad
// blocking is enabled and this is a subresource factory. No-op otherwise.
// `first_party_host` is the top-frame origin's host (from the IsolationInfo),
// consulted per-request against the user allowlist.
// Called from ChromeContentBrowserClient::WillCreateURLLoaderFactory.
void MaybeProxyAdblock(network::URLLoaderFactoryBuilder& factory_builder,
                       bool is_subresource,
                       const std::string& first_party_host);

}  // namespace mori

#endif  // CHROME_BROWSER_UI_MORI_MORI_ADBLOCK_H_

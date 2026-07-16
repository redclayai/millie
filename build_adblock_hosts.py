#!/usr/bin/env python3
"""Build Millie's offline ad/tracker host blocklist.

Downloads open, widely-used ad- and tracker-host feeds (Block List Project's
ads + tracking lists and Peter Lowe's ad-server list), normalizes each host,
and writes a compact sorted binary of 64-bit SHA-256 host-hash prefixes that
Millie's built-in ad blocker loads at runtime. Host-based (Pi-hole style):
a subresource request whose host — or any parent domain — is listed is
cancelled at the network layer. No per-navigation network calls; the check is
fully local, matching Millie's ungoogled-chromium / zero-telemetry posture.

This mirrors build_threatlist.py exactly, with a distinct magic so the ad list
and the phishing/malware list never get confused for one another.

File format (little-endian header, big-endian entries):
    magic  : 4 bytes  b"MAB1"   (Millie Ad Blocklist v1)
    count  : uint32 LE
    entries: count * uint64 BE   (sorted ascending; SHA-256(host)[:8])

Usage: build_adblock_hosts.py [out_path]   (default: overlay/adhosts.bin)
"""
import hashlib
import struct
import sys
import urllib.request

FEEDS = [
    # (url, kind) — "hostfile" = "0.0.0.0/127.0.0.1 <host>" lines; "domains" = one host per line
    # Block List Project — the list the Settings copy already references.
    ("https://raw.githubusercontent.com/blocklistproject/Lists/master/ads.txt", "hostfile"),
    ("https://raw.githubusercontent.com/blocklistproject/Lists/master/tracking.txt", "hostfile"),
    # Peter Lowe's ad + tracking server list (long-standing, conservative).
    ("https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext", "hostfile"),
]


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "MillieAdblockBuilder/1"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8", "replace")


def normalize(host):
    host = host.strip().lower().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    # Reject obvious non-hosts and localhost sentinels used as list terminators.
    if not host or " " in host or "/" in host or "." not in host:
        return None
    if host in ("localhost", "localhost.localdomain", "local", "broadcasthost"):
        return None
    return host


def hosts_from(text, kind):
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if kind == "hostfile":
            parts = line.split()
            if len(parts) < 2:
                continue
            raw = parts[1]
        else:
            raw = line
        h = normalize(raw)
        if h:
            yield h


# Upstream false positives: bare product domains whose presence blocks an
# entire app (the C++ matcher walks parent domains, so `powerbi.com` kills
# every app.powerbi.com subresource). Excluded at build time; the telemetry
# subdomains of these products remain separately listed and blocked.
ALLOWLIST = {
    "powerbi.com",      # broke app.powerbi.com entirely (2026-07-16)
    "salesforce.com",
    "intercom.io",      # support chat widgets + app.intercom.io
    "datadoghq.com",
    "tableau.com",
}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "overlay/adhosts.bin"
    prefixes = set()
    for url, kind in FEEDS:
        try:
            text = fetch(url)
        except Exception as e:  # noqa: BLE001
            print(f"WARN: failed to fetch {url}: {e}", file=sys.stderr)
            continue
        n = 0
        for host in hosts_from(text, kind):
            if host in ALLOWLIST:
                continue
            digest = hashlib.sha256(host.encode("utf-8")).digest()
            prefixes.add(struct.unpack(">Q", digest[:8])[0])
            n += 1
        print(f"  {url.split('/')[2]}: {n} hosts")
    ordered = sorted(prefixes)
    with open(out, "wb") as f:
        f.write(b"MAB1")
        f.write(struct.pack("<I", len(ordered)))
        for p in ordered:
            f.write(struct.pack(">Q", p))
    print(f"wrote {out}: {len(ordered)} unique host prefixes ({8 * len(ordered) + 8} bytes)")


if __name__ == "__main__":
    main()

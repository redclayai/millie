#!/usr/bin/env python3
"""Build Millie's offline phishing/malware host blocklist.

Downloads open, privacy-respecting feeds (URLhaus malware hosts + the
Phishing.Database active-phishing domains), normalizes each host, and writes a
compact sorted binary of 64-bit SHA-256 host-hash prefixes that ThreatStore
loads at runtime. No per-navigation network calls — the check is fully local.

File format (little-endian header, big-endian entries):
    magic  : 4 bytes  b"MTL1"
    count  : uint32 LE
    entries: count * uint64 BE  (sorted ascending; SHA-256(host)[:8])

Usage: build_threatlist.py [out_path]   (default: overlay/threatlist.bin)
"""
import hashlib
import struct
import sys
import urllib.request

FEEDS = [
    # (url, kind) — "hostfile" = "0.0.0.0/127.0.0.1 <host>" lines; "domains" = one host per line
    ("https://urlhaus.abuse.ch/downloads/hostfile/", "hostfile"),
    ("https://raw.githubusercontent.com/mitchellkrogza/Phishing.Database/master/phishing-domains-ACTIVE.txt", "domains"),
]


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "MillieThreatlistBuilder/1"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode("utf-8", "replace")


def normalize(host):
    host = host.strip().lower().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    # Reject obvious non-hosts.
    if not host or " " in host or "/" in host or "." not in host:
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


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "overlay/threatlist.bin"
    prefixes = set()
    for url, kind in FEEDS:
        try:
            text = fetch(url)
        except Exception as e:  # noqa: BLE001
            print(f"WARN: failed to fetch {url}: {e}", file=sys.stderr)
            continue
        n = 0
        for host in hosts_from(text, kind):
            digest = hashlib.sha256(host.encode("utf-8")).digest()
            prefixes.add(struct.unpack(">Q", digest[:8])[0])
            n += 1
        print(f"  {url.split('/')[2]}: {n} hosts")
    ordered = sorted(prefixes)
    with open(out, "wb") as f:
        f.write(b"MTL1")
        f.write(struct.pack("<I", len(ordered)))
        for p in ordered:
            f.write(struct.pack(">Q", p))
    print(f"wrote {out}: {len(ordered)} unique host prefixes ({8 * len(ordered) + 8} bytes)")


if __name__ == "__main__":
    main()

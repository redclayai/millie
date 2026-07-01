import Foundation
import CryptoKit

/// Offline phishing / malware host blocklist. Loads a compact sorted table of
/// 64-bit SHA-256 host-hash prefixes (built by `build_threatlist.py` from the
/// URLhaus and Phishing.Database open feeds, bundled as `threatlist.bin`) and
/// answers host lookups with **zero network calls** — the check is fully local,
/// so it adds threat protection without the telemetry ungoogled-chromium drops.
///
/// A URL is blocked when its host, or any parent domain down to the two-label
/// root, exactly matches a listed host (www- and case-normalized), mirroring
/// how the feeds enumerate malicious hosts.
final class ThreatStore {
    static let shared = ThreatStore()

    private let prefixes: [UInt64]   // sorted ascending; SHA-256(host)[0..<8], big-endian

    private init() {
        prefixes = ThreatStore.load()
        NSLog("MILLIE_THREATLIST loaded %d host prefixes", prefixes.count)
    }

    /// True when the URL's host (or a parent domain) is on the blocklist.
    func isBlocked(urlString: String) -> Bool {
        guard !prefixes.isEmpty, let host = Self.host(from: urlString) else { return false }
        for candidate in Self.candidates(for: host) where contains(Self.hash(candidate)) {
            return true
        }
        return false
    }

    var isLoaded: Bool { !prefixes.isEmpty }

    // MARK: - Loading

    private static func load() -> [UInt64] {
        guard let url = Bundle.main.url(forResource: "threatlist", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              data.count >= 8,
              data.prefix(4).elementsEqual(Array("MTL1".utf8)) else {
            return []
        }
        let count = Int(data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }.littleEndian)
        guard count > 0, data.count >= 8 + count * 8 else { return [] }
        var out = [UInt64](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: 8 + i * 8, as: UInt64.self))
            }
        }
        return out
    }

    // MARK: - Lookup

    private func contains(_ value: UInt64) -> Bool {
        var lo = 0, hi = prefixes.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = prefixes[mid]
            if v == value { return true }
            if v < value { lo = mid + 1 } else { hi = mid - 1 }
        }
        return false
    }

    private static func hash(_ host: String) -> UInt64 {
        var v: UInt64 = 0
        for (i, byte) in SHA256.hash(data: Data(host.utf8)).enumerated() {
            if i == 8 { break }
            v = (v << 8) | UInt64(byte)
        }
        return v
    }

    /// The normalized host plus its parent domains down to the two-label root:
    /// `login.pay.evil.com` → `login.pay.evil.com`, `pay.evil.com`, `evil.com`.
    private static func candidates(for host: String) -> [String] {
        var labels = host.split(separator: ".").map(String.init)
        var result: [String] = []
        while labels.count >= 2 {
            result.append(labels.joined(separator: "."))
            labels.removeFirst()
        }
        return result
    }

    private static func host(from urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = comps.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.isEmpty ? nil : host
    }
}

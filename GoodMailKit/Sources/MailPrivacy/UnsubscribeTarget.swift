import Darwin
import Foundation

/// Where an unsubscribe request may go. A list's headers are written by whoever sent the mail, so a
/// one-click POST must not be steerable at the user's own network (router admin pages, printers, localhost).
public enum UnsubscribeTarget {
    /// Syntax only: https, a DNS name of at least two labels (never an IP literal or a name that resolves
    /// locally), no user info, the default port. The resolved addresses are checked separately with `isPublic`.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              var host = url.host(percentEncoded: false)?.lowercased()
        else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A top-level domain starts with a letter; resolvers read numeric forms such as "2130706433" or
        // "0x7f.1" as IPv4 addresses.
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }),
              labels.last?.first?.isLetter == true,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
              !localSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return false }
        return true
    }

    static let localSuffixes = ["localhost", "local", "localdomain", "internal", "home.arpa", "lan", "intranet"]

    /// Whether a numeric IPv4 or IPv6 address is reachable on the public internet. False for anything that
    /// doesn't parse, and for private, loopback, link-local, unique-local, CGNAT, multicast, reserved,
    /// documentation and unspecified addresses, including such IPv4 addresses embedded in IPv6 forms.
    public static func isPublic(address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return isPublic(v4: withUnsafeBytes(of: v4.s_addr) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return isPublic(v6: withUnsafeBytes(of: v6) { Array($0) })
        }
        return false
    }

    static func isPublic(v4 bytes: [UInt8]) -> Bool {
        let (a, b, c) = (bytes[0], bytes[1], bytes[2])
        switch a {
        case 0, 10, 127: return false                          // "this network", private, loopback
        case 100 where (64...127).contains(b): return false    // CGNAT 100.64/10
        case 169 where b == 254: return false                   // link-local
        case 172 where (16...31).contains(b): return false     // private 172.16/12
        case 192 where b == 168: return false                   // private
        case 192 where b == 0 && (c == 0 || c == 2): return false // IETF protocol assignments, TEST-NET-1
        case 198 where b == 18 || b == 19: return false         // benchmarking 198.18/15
        case 198 where b == 51 && c == 100: return false        // TEST-NET-2
        case 203 where b == 0 && c == 113: return false         // TEST-NET-3
        case 224...255: return false                            // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublic(v6 bytes: [UInt8]) -> Bool {
        let first = bytes[0]
        let isZero = { (range: Range<Int>) in bytes[range].allSatisfy { $0 == 0 } }
        if isZero(0..<16) || (isZero(0..<15) && bytes[15] == 1) { return false } // unspecified, loopback
        if first == 0xFF { return false }                                         // multicast ff00::/8
        if first == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }              // link-local fe80::/10
        if first == 0xFE && bytes[1] & 0xC0 == 0xC0 { return false }              // site-local fec0::/10
        if first & 0xFE == 0xFC { return false }                                  // unique local fc00::/7
        if first == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 { return false } // 2001:db8::/32
        if first == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0 { return false } // Teredo 2001::/32
        if first == 0x01 && isZero(1..<8) { return false }                        // discard 100::/64
        // IPv4-mapped ::ffff:0:0/96, IPv4-compatible ::/96 and NAT64 64:ff9b::/96 carry an IPv4 address.
        if isZero(0..<10) && bytes[10] == 0xFF && bytes[11] == 0xFF { return isPublic(v4: Array(bytes[12..<16])) }
        if isZero(0..<12) { return false }
        if bytes[0..<12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublic(v4: Array(bytes[12..<16])) }
        if first == 0x20 && bytes[1] == 0x02 { return isPublic(v4: Array(bytes[2..<6])) } // 6to4 2002::/16
        return true
    }
}

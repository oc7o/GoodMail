import Darwin
import Foundation

/// Finds the addresses a host name resolves to, as numeric strings ("93.184.216.34", "2606:2800:220:1::1").
public protocol HostResolver: Sendable {
    func addresses(of host: String) async throws -> [String]
}

/// The system's resolver (`getaddrinfo`), which blocks while it waits for DNS, so it runs on a dispatch queue
/// rather than on a thread of the concurrency pool.
public struct SystemHostResolver: HostResolver {
    public init() {}

    public func addresses(of host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.lookUp(host) })
            }
        }
    }

    static func lookUp(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "443", &hints, &list)
        guard status == 0 else { throw HostResolutionError(code: status) }
        defer { freeaddrinfo(list) }
        var addresses: [String] = []
        var entry = list
        while let info = entry?.pointee {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let found = getnameinfo(
                info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            if found == 0 {
                let address = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if !addresses.contains(address) { addresses.append(address) }
            }
            entry = info.ai_next
        }
        return addresses
    }
}

/// Answers every lookup with the same addresses: for the demo account, whose `.example` hosts don't resolve.
public struct FixedHostResolver: HostResolver {
    private let answer: [String]

    public init(_ addresses: [String]) {
        answer = addresses
    }

    public func addresses(of host: String) async throws -> [String] {
        answer
    }
}

public struct HostResolutionError: Error, Equatable, Sendable, LocalizedError {
    /// The `getaddrinfo` error, such as `EAI_NONAME`.
    public var code: Int32

    public var errorDescription: String? {
        String(cString: gai_strerror(code))
    }
}

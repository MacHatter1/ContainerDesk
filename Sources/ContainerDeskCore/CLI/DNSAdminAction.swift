import Darwin
import Foundation

public enum DNSAdminAction: Sendable, Equatable {
    case create(domainName: String, localhost: String?)
    case delete(domainName: String)

    public var arguments: [String] {
        switch self {
        case .create(let domainName, let localhost):
            var values = ["system", "dns", "create"]
            if let localhost { values += ["--localhost", localhost] }
            values.append(domainName)
            return values
        case .delete(let domainName): return ["system", "dns", "delete", domainName]
        }
    }

    public var activityTitle: String {
        switch self {
        case .create(let domain, _): "Add DNS domain \(domain)"
        case .delete(let domain): "Remove DNS domain \(domain)"
        }
    }

    public func validate() throws {
        let domain: String
        switch self {
        case .create(let domainName, let localhost):
            domain = domainName
            if let localhost, !Self.isIPAddress(localhost) { throw DNSAdminError.invalidAddress }
        case .delete(let domainName): domain = domainName
        }
        guard Self.isDomain(domain) else { throw DNSAdminError.invalidDomain }
    }

    private static func isDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !value.hasSuffix(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.utf8.count),
                  let first = label.utf8.first, let last = label.utf8.last,
                  isAlphaNumeric(first), isAlphaNumeric(last) else { return false }
            return label.utf8.allSatisfy { isAlphaNumeric($0) || $0 == 45 }
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

public enum DNSAdminError: Error, LocalizedError, Sendable {
    case invalidDomain
    case invalidAddress
    case launch(String)
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDomain: "Enter a valid DNS domain name."
        case .invalidAddress: "Enter a valid IPv4 or IPv6 address for the localhost target."
        case .launch(let message), .command(let message): message
        }
    }
}

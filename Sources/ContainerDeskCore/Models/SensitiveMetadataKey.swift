import Foundation

/// One policy for credential-shaped JSON keys and curated resource labels.
enum SensitiveMetadataKey {
    private static let fragments = ["password", "passwd", "token", "secret", "authorization", "credential", "privatekey", "accesskey", "apikey"]

    static func normalized(_ key: String) -> String { key.lowercased().filter(\.isLetter) }

    static func containsCredential(_ key: String) -> Bool {
        let key = normalized(key)
        return fragments.contains { key.contains($0) }
    }
}

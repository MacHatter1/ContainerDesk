import Foundation

/// One policy for credential-shaped JSON keys and curated resource labels.
enum SensitiveMetadataKey {
    private static let fragments = ["password", "passwd", "passphrase", "token", "secret", "authorization", "credential", "privatekey", "accesskey", "apikey", "sessioncookie"]

    static func normalized(_ key: String) -> String { key.lowercased().filter(\.isLetter) }

    static func containsCredential(_ key: String) -> Bool {
        let words = key.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { ["pass", "pwd", "auth"].contains(String($0)) }) { return true }
        let key = normalized(key)
        return fragments.contains { key.contains($0) }
    }
}

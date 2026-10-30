import Foundation

/// One policy for CLI previews, captured output and structured Inspect argv.
/// Scan through passthrough separators too: guest commands can carry credentials.
enum CredentialArguments {
    static let flags: Set<String> = ["--password", "--passwd", "--token", "--secret", "--auth", "--authorization", "--api-key", "--access-key", "--secret-key", "--private-key"]

    struct Substitution {
        let index: Int
        let replacement: String
        let secret: String?
    }

    static func substitutions(in arguments: [String?]) -> [Substitution] {
        var result: [Substitution] = []
        var index = 0
        while index < arguments.count {
            guard let argument = arguments[index] else { index += 1; continue }
            if let equals = argument.firstIndex(of: "="), flags.contains(argument[..<equals].lowercased()) {
                result.append(.init(index: index, replacement: String(argument[...equals]) + "••••", secret: String(argument[argument.index(after: equals)...])))
            } else if flags.contains(argument.lowercased()), index + 1 < arguments.count {
                index += 1
                result.append(.init(index: index, replacement: "••••", secret: arguments[index]))
            }
            index += 1
        }
        return result
    }
}

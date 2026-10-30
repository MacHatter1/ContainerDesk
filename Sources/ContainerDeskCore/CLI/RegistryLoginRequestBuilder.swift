import Foundation

public enum RegistryLoginRequestBuilder {
    public static func request(server: String, scheme: String, username: String, password: String) throws -> CommandRequest {
        let input = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = input.contains("://") ? input : "\(scheme)://\(input)"
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/" || (host.lowercased() == "index.docker.io" && ["/v1", "/v1/"].contains(components.path)),
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw RegistryLoginError.invalidServer
        }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let server = authority + (components.port.map { ":\($0)" } ?? "")
        return CommandRequest(
            arguments: ["registry", "login", "--scheme", scheme, "--username", username, "--password-stdin", server],
            stdin: Data((password + "\n").utf8), redactions: [password]
        )
    }
}

public enum RegistryLoginError: Error, LocalizedError {
    case invalidServer
    public var errorDescription: String? { "Enter a registry host with an optional port or an HTTP/HTTPS URL without credentials, a path, or a query." }
}

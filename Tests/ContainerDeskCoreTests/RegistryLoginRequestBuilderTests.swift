import Foundation
import Testing
import ContainerDeskCore

struct RegistryLoginRequestBuilderTests {
    @Test(arguments: ["https://registry.example:5000", "registry.example:5000"])
    func preservesCustomRegistryPorts(_ server: String) throws {
        let request = try RegistryLoginRequestBuilder.request(server: server, scheme: "https", username: "user", password: "fixture-password")
        #expect(request.arguments == ["registry", "login", "--scheme", "https", "--username", "user", "--password-stdin", "registry.example:5000"])
        #expect(request.stdin == Data("fixture-password\n".utf8))
        #expect(!request.preview.contains("fixture-password"))
    }

    @Test func preservesIPv6AuthorityAndHonorsExplicitURLScheme() throws {
        let request = try RegistryLoginRequestBuilder.request(server: "http://[::1]:5001/", scheme: "https", username: "user", password: "fixture")
        #expect(request.arguments.last == "[::1]:5001")
        #expect(request.arguments[3] == "http")
    }

    @Test func acceptsThePreviouslySuggestedDockerHubLoginURL() throws {
        let request = try RegistryLoginRequestBuilder.request(server: "https://index.docker.io/v1/", scheme: "https", username: "user", password: "fixture")
        #expect(request.arguments.last == "index.docker.io")
    }

    @Test(arguments: ["https://user:password@registry.example", "https://registry.example/path", "https://registry.example?token=value", "file:///tmp/registry", "https://registry.example:70000", "https://"])
    func rejectsAmbiguousOrInvalidRegistryEndpoints(_ server: String) {
        #expect(throws: RegistryLoginError.self) {
            try RegistryLoginRequestBuilder.request(server: server, scheme: "https", username: "user", password: "fixture")
        }
    }
}

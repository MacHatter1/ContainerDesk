import Foundation
import Testing
@testable import ContainerDeskCore

struct CommandAndDNSValidationTests {
    @Test func commandPreviewQuotesAndRedactsValues() {
        let request = CommandRequest(arguments: ["registry", "login", "registry.example", "--token", "secret with spaces"], redactions: ["secret with spaces"])
        #expect(request.preview.contains("registry.example"))
        #expect(request.preview.contains("••••"))
        #expect(!request.preview.contains("secret"))
    }

    @Test func commandPreviewAutomaticallyHidesCommonCredentialFlags() {
        let request = CommandRequest(arguments: ["registry", "login", "example.invalid", "--password", "plain-text-secret"])
        #expect(!request.preview.contains("plain-text-secret"))
        #expect(request.preview.contains("••••"))
    }

    @Test func commandPreviewRedactsBeforeShellDisplayEscapingAndHandlesOverlaps() {
        let request = CommandRequest(arguments: ["--env", "KEY=foo'bar\nnext"], redactions: ["foo", "foo'bar\nnext"])
        #expect(!request.preview.contains("foo"))
        #expect(!request.preview.contains("next"))
    }

    @Test func sanitizesRuntimeCredentialAssignmentsInErrorOutput() {
        let request = CommandRequest(arguments: ["run"])
        let output = request.sanitizeOutput("Error: CONTAINERDESK_TEST_SECRET=smoke-value with spaces; API_TOKEN=other\n{\"password\":\"third-value\"}")
        #expect(!output.contains("smoke-value"))
        #expect(!output.contains("other"))
        #expect(!output.contains("third-value"))
        #expect(output.contains("CONTAINERDESK_TEST_SECRET=••••"))
    }

    @Test func normalizedEnvironmentPreservesCredentialsAndAddsHomebrewToPath() {
        let environment = ExecutableResolver.normalizedEnvironment(
            inherited: ["PATH": "/bin:/usr/bin", "HOME": "/tmp/user", "SSH_AUTH_SOCK": "/tmp/agent"],
            additional: ["LANG": "en_GB.UTF-8"]
        )
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin")
        #expect(environment["HOME"] == "/tmp/user")
        #expect(environment["SSH_AUTH_SOCK"] == "/tmp/agent")
        #expect(environment["LANG"] == "en_GB.UTF-8")
    }

    @Test func dnsAdminAllowsOnlyValidDomainAndAddressInputs() throws {
        try DNSAdminAction.create(domainName: "dev.example", localhost: "127.0.0.1").validate()
        try DNSAdminAction.create(domainName: "dev.example", localhost: "::1").validate()
        #expect(throws: DNSAdminError.self) { try DNSAdminAction.delete(domainName: "-unsafe.example").validate() }
        #expect(throws: DNSAdminError.self) { try DNSAdminAction.create(domainName: "dev.example", localhost: "not-an-address").validate() }
    }
}

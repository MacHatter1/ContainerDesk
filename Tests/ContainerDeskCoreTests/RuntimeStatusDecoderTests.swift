import Testing
@testable import ContainerDeskCore

struct RuntimeStatusDecoderTests {
    @Test func decodesRunningAndArchitecture() {
        let summary = RuntimeStatusDecoder.decode("status running\nhost.architecture arm64\n")
        #expect(summary.state == .running)
        #expect(summary.rawState == "running")
        #expect(summary.architecture == "arm64")
    }

    @Test func decodesStoppedWithoutCallingItConnected() {
        let summary = RuntimeStatusDecoder.decode("status stopped\nhost.architecture arm64\n")
        #expect(summary.state == .stopped)
        #expect(summary.rawState == "stopped")
    }

    @Test func unknownOrMalformedStatusDoesNotAssumeRunning() {
        #expect(RuntimeStatusDecoder.decode("status starting\n").state == .unknown)
        #expect(RuntimeStatusDecoder.decode("unexpected output\n").state == .unknown)
    }

    @Test func recognizesInstalledPluginUsageAndRejectsGenericRootHelp() {
        #expect(CLIPluginHelpDecoder.isAvailable(plugin: "compose", succeeded: true, output: "OVERVIEW: compose\nUSAGE: compose <subcommand>\n"))
        #expect(CLIPluginHelpDecoder.isAvailable(plugin: "k8s", succeeded: true, output: "USAGE: k8s <subcommand>\n"))
        #expect(!CLIPluginHelpDecoder.isAvailable(plugin: "compose", succeeded: true, output: "USAGE: container <subcommand>\nSUBCOMMANDS: compose\n"))
        #expect(!CLIPluginHelpDecoder.isAvailable(plugin: "compose", succeeded: false, output: "USAGE: compose <subcommand>\n"))
    }
}

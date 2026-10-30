import Testing
import ContainerDeskCore
@testable import ContainerDeskApp

struct SystemServiceActionsTests {
    @Test func advancedServiceStopUsesTheSharedWarningInSummaryAndConfirmation() throws {
        let stop = try #require(AdvancedCommandCatalog.specs(for: .system).first { $0.arguments == ["system", "stop"] })
        #expect(stop.destructive)
        #expect(stop.summary == SystemServiceActions.stopConfirmation)
        #expect(stop.confirmationMessage == SystemServiceActions.stopConfirmation)
    }
    @Test func stopConfirmationDisclosesWorkloadShutdownAndManualRestart() {
        let message = SystemServiceActions.stopConfirmation.lowercased()
        #expect(message.contains("stops all running containers"))
        #expect(message.contains("start the containers manually"))
        #expect(message.contains("data remains on disk"))
        #expect(!message.contains("continue after"))
    }
}

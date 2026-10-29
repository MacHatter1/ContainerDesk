import ContainerDeskCore
import Testing
@testable import ContainerDeskApp

struct ResourceActionValidationTests {
    @Test func selectedActionTargetSeedsAndUsesOneTrimmedEditableValue() {
        #expect(ResourceActionTargetValue.initial(selectedResourceID: "container-123") == "container-123")
        #expect(ResourceActionTargetValue.initial(selectedResourceID: "  image:tag  ") == "image:tag")
        #expect(ResourceActionTargetValue.normalized("  replacement:tag\n") == "replacement:tag")
        #expect(ResourceActionTargetValue.normalized(" \n\t ").isEmpty)
        #expect(ResourceActionTargetValue.initial(selectedResourceID: nil).isEmpty)
        #expect(ResourceActionTargetValue.positionalArguments("--all") == ["--", "--all"])
        #expect(ResourceActionTargetValue.confirmationLabel("--all") == "“--all”")
    }

    @Test func targetOrAllValidationMatchesDestructiveCatalogActions() {
        let targetedActions: [(ContainerSection, String)] = [
            (.containers, "stop"), (.containers, "kill"), (.containers, "delete"),
            (.images, "delete"), (.volumes, "delete"), (.networks, "delete"),
        ]

        for (section, commandID) in targetedActions {
            #expect(!AdvancedCommandScopeValidation.isValid(section: section, commandID: commandID, positionals: [], flags: []))
            #expect(!AdvancedCommandScopeValidation.isValid(section: section, commandID: commandID, positionals: ["  \n"], flags: []))
            #expect(AdvancedCommandScopeValidation.isValid(section: section, commandID: commandID, positionals: ["resource-1"], flags: []))
            #expect(AdvancedCommandScopeValidation.isValid(section: section, commandID: commandID, positionals: [], flags: ["all"]))
            #expect(!AdvancedCommandScopeValidation.isValid(section: section, commandID: commandID, positionals: ["resource-1"], flags: ["all"]))
        }
    }

    @Test func validationDoesNotRequireTargetsForDefaultOrPruneCommands() {
        #expect(AdvancedCommandScopeValidation.isValid(section: .machines, commandID: "stop", positionals: [], flags: []))
        #expect(AdvancedCommandScopeValidation.isValid(section: .volumes, commandID: "prune", positionals: [], flags: []))
        #expect(AdvancedCommandScopeValidation.isValid(section: .networks, commandID: "prune", positionals: [], flags: []))
    }

    @Test func optionShapedAdvancedTargetRemainsOneLiteralTarget() {
        #expect(AdvancedCommandScopeValidation.isValid(section: .containers, commandID: "delete", positionals: ["--all"], flags: []))
        #expect(AdvancedCommandScopeValidation.confirmationLabel("--all") == "“--all”")
        #expect(AdvancedCommandScopeValidation.positionalTerminator(section: .containers, commandID: "delete", positionals: ["--all"]) == ["--"])
        #expect(AdvancedCommandScopeValidation.positionalTerminator(section: .images, commandID: "delete", positionals: ["--all"]) == ["--"])
        #expect(AdvancedCommandScopeValidation.positionalTerminator(section: .volumes, commandID: "delete", positionals: ["--all"]) == ["--"])
        #expect(AdvancedCommandScopeValidation.positionalTerminator(section: .networks, commandID: "delete", positionals: ["--all"]) == ["--"])
        #expect(AdvancedCommandScopeValidation.positionalTerminator(section: .containers, commandID: "delete", positionals: []) == [])
        #expect(AdvancedCommandScopeValidation.positionalTerminator(section: .containers, commandID: "stop", positionals: ["container-1"]) == ["--"])
    }
}

import Testing
@testable import StaveCore

struct MenuGateAndLaunchTests {
    @Test func onlyCompactModeRunsWithASheetUp() {
        for command in MenuCommand.allCases {
            #expect(MenuCommandGate.allowedWhileSheetUp(command) == (command == .toggleCompactMode))
        }
    }

    @Test func busyWhenAnySignalIsSet() {
        #expect(!MenuCommandGate.isBusy(hasAttachedSheet: false, isPicking: false, hasPendingSheet: false))
        #expect(MenuCommandGate.isBusy(hasAttachedSheet: true, isPicking: false, hasPendingSheet: false))
        #expect(MenuCommandGate.isBusy(hasAttachedSheet: false, isPicking: true, hasPendingSheet: false))
        #expect(MenuCommandGate.isBusy(hasAttachedSheet: false, isPicking: false, hasPendingSheet: true))
    }

    @Test func arcHomeIsIsolatedWhenOnlyTheDataFolderIsGiven() throws {
        let only = try LaunchArguments.parse(["Stave", "-StaveDataDirectory", "/private/tmp/x/data"])
        #expect(only.effectiveArcHome == "/private/tmp/x/data/arc-home-isolated")
        let both = try LaunchArguments.parse(["Stave", "-StaveDataDirectory", "/private/tmp/x/data", "-StaveArcHome", "/private/tmp/x/home"])
        #expect(both.effectiveArcHome == "/private/tmp/x/home")
        let neither = try LaunchArguments.parse(["Stave"])
        #expect(neither.effectiveArcHome == nil)
        let homeOnly = try LaunchArguments.parse(["Stave", "-StaveArcHome", "/private/tmp/x/home"])
        #expect(homeOnly.effectiveArcHome == "/private/tmp/x/home")
    }
}

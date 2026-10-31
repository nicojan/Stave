import Foundation
import Testing
@testable import StaveCore

struct WorkspaceMenuTests {
    @Test func middleWorkspaceHasEveryItem() {
        #expect(WorkspaceMenus.items(index: 1, count: 3).map(\.action) == [.edit, .moveLeft, .moveRight, .delete])
    }

    @Test func firstHasNoMoveLeftAndLastHasNoMoveRight() {
        #expect(WorkspaceMenus.items(index: 0, count: 3).map(\.action) == [.edit, .moveRight, .delete])
        #expect(WorkspaceMenus.items(index: 2, count: 3).map(\.action) == [.edit, .moveLeft, .delete])
    }

    @Test func onlyWorkspaceCannotBeDeletedOrMoved() {
        let items = WorkspaceMenus.items(index: 0, count: 1)
        #expect(items == [WorkspaceMenuItem(action: .edit), WorkspaceMenuItem(action: .delete, isEnabled: false)])
        #expect(WorkspaceMenus.items(index: 0, count: 2).last == WorkspaceMenuItem(action: .delete, isEnabled: true))
    }

    @Test func moveTargets() {
        let ids = (0..<4).map { _ in UUID() }
        #expect(WorkspaceMenus.moveTarget(.moveLeft, index: 1, ids: ids) == .init(afterID: nil))
        #expect(WorkspaceMenus.moveTarget(.moveLeft, index: 3, ids: ids) == .init(afterID: ids[1]))
        #expect(WorkspaceMenus.moveTarget(.moveRight, index: 0, ids: ids) == .init(afterID: ids[1]))
        #expect(WorkspaceMenus.moveTarget(.moveLeft, index: 0, ids: ids) == nil)
        #expect(WorkspaceMenus.moveTarget(.moveRight, index: 3, ids: ids) == nil)
        #expect(WorkspaceMenus.moveTarget(.edit, index: 1, ids: ids) == nil)
        #expect(WorkspaceMenus.moveTarget(.moveRight, index: 9, ids: ids) == nil)
    }

    @Test func deleteConfirmationText() {
        #expect(WorkspaceMenus.deleteConfirmation(name: "Work") == "Delete “Work”? Its tabs go to the archive.")
    }

    @Test func everyActionHasTitleAndSymbol() {
        for action in WorkspaceAction.allCases { #expect(!action.title.isEmpty && !action.symbol.isEmpty) }
    }

    @Test func shortcutDigitsOnlyForFirstNineAndOnlyWhenOn() {
        #expect(WorkspaceMenus.shortcutDigit(index: 0, enabled: true) == 1)
        #expect(WorkspaceMenus.shortcutDigit(index: 8, enabled: true) == 9)
        #expect(WorkspaceMenus.shortcutDigit(index: 9, enabled: true) == nil)
        #expect(WorkspaceMenus.shortcutDigit(index: 0, enabled: false) == nil)
    }

    @Test func switchItemsMarkCurrentAndNumberTheFirstNine() {
        let spaces = (0..<10).map { Workspace(profileID: UUID(), name: "W\($0)", icon: "", colorHex: "#8E8E93", sortIndex: Double($0)) }
        let items = WorkspaceMenus.switchItems(workspaces: spaces, currentID: spaces[1].id, shortcutsEnabled: true)
        #expect(items.count == 10)
        #expect(items.map(\.shortcutDigit) == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil])
        #expect(items.filter(\.isCurrent).map(\.title) == ["W1"])
        let off = WorkspaceMenus.switchItems(workspaces: spaces, currentID: spaces[0].id, shortcutsEnabled: false)
        #expect(off.allSatisfy { $0.shortcutDigit == nil })
    }

    @Test func profileMenuAndNameRules() {
        #expect(!WorkspaceMenus.showsProfileMenu(profileCount: 1))
        #expect(WorkspaceMenus.showsProfileMenu(profileCount: 2))
        #expect(WorkspaceMenus.profileName(typed: "  Side  ") == "Side")
        #expect(WorkspaceMenus.profileName(typed: "  \n ") == nil)
    }
}

struct WorkspaceEditorRulesTests {
    @Test func paletteHasEightColoursAndHomeGrey() {
        #expect(WorkspaceEditorRules.colors.count == 9)
        #expect(WorkspaceEditorRules.colors.last?.hex == "#8E8E93")
        #expect(Set(WorkspaceEditorRules.colors.map(\.hex)).count == 9)
        #expect(WorkspaceEditorRules.colors.allSatisfy { HexColor.rgb($0.hex) != nil })
        #expect(WorkspaceEditorRules.symbols.count == 12)
        #expect(Set(WorkspaceEditorRules.symbols.map(\.symbol)).count == 12)
    }

    @Test func nameIsTrimmedAndEmptyIsRejected() {
        let draft = WorkspaceEditorRules.validate(name: "  Work \n", icon: "", colorHex: "#3478F6")
        #expect(draft == WorkspaceDraft(name: "Work", icon: "", colorHex: "#3478F6"))
        #expect(WorkspaceEditorRules.validate(name: "   ", icon: "", colorHex: "#3478F6") == nil)
        #expect(WorkspaceEditorRules.validate(name: "", icon: "", colorHex: "#3478F6") == nil)
    }

    @Test func iconIsEmptyEmojiOrListedSymbol() {
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "💼", colorHex: "#3478F6")?.icon == "💼")
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "briefcase", colorHex: "#3478F6")?.icon == "briefcase")
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "", colorHex: "#3478F6")?.icon == "")
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "not.a.symbol", colorHex: "#3478F6") == nil)
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "ab", colorHex: "#3478F6") == nil)
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "💼💼", colorHex: "#3478F6") == nil)
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "é", colorHex: "#3478F6") == nil)
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "7", colorHex: "#3478F6") == nil)
    }

    @Test func colourMustBeInThePaletteCaseInsensitively() {
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "", colorHex: "#3478f6")?.colorHex == "#3478F6")
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "", colorHex: "#123456") == nil)
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "", colorHex: "red") == nil)
    }

    @Test func anEditedWorkspacesOwnIconAndColourStayValidWhenUnchanged() {
        #expect(WorkspaceEditorRules.validate(name: "A", icon: "star.fill", colorHex: "#123456") == nil)
        let kept = WorkspaceEditorRules.validate(name: "A", icon: "star.fill", colorHex: "#123456", allowingIcon: "star.fill", allowingColorHex: "#123456")
        #expect(kept == WorkspaceDraft(name: "A", icon: "star.fill", colorHex: "#123456"))
        #expect(WorkspaceEditorRules.colorChoices(including: "#123456").last == PaletteColor(name: "Current", hex: "#123456"))
        #expect(WorkspaceEditorRules.colorChoices(including: "#3478f6").count == 9)
        #expect(WorkspaceEditorRules.symbolChoices(including: "star.fill").count == 13)
        #expect(WorkspaceEditorRules.symbolChoices(including: "💼").count == 12)
        #expect(WorkspaceEditorRules.symbolChoices(including: "house").count == 12)
    }
}

@MainActor
struct WorkspaceShortcutsSettingTests {
    @Test func defaultsOnAndChangesAreVisibleAndPersisted() throws {
        let (store, _, _) = try makeTempStore()
        let setting = WorkspaceShortcutsSetting(store: store)
        #expect(setting.isEnabled)
        setting.set(false)
        #expect(!setting.isEnabled)
        #expect(try store.setting(SettingKeys.workspaceShortcutsEnabled) == false)
        #expect(!WorkspaceShortcutsSetting(store: store).isEnabled)
        setting.set(true)
        #expect(try store.setting(SettingKeys.workspaceShortcutsEnabled))
    }
}

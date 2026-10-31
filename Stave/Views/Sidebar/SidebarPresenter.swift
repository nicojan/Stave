import AppKit
import Observation
import StaveCore

/// One request from the Tab menu. The serial makes a repeat of the same request a new value.
struct SidebarActionRequest: Equatable {
    let serial: Int
    let action: SidebarAction
    let item: SidebarItemID?
}

/// Window-level UI requests that menus, the command bar and the sidebar make of one another: the workspace editor, the archive popover,
/// the new-profile prompt and the command bar itself. Holds presentation state only; every rule is in StaveCore.
@MainActor @Observable
final class SidebarPresenter {
    var workspaceEditor: WorkspaceEditorMode?
    /// The archive as a popover (a mouse click on its button) ...
    var showArchive = false
    /// ... or as a sheet (anything else: keyboard, command bar, menu), which takes the keyboard where a popover does not.
    var showArchiveSheet = false
    var showNewProfile = false
    /// The first-run or Arc import sheet on this window, if any.
    var sheet: WindowSheet?
    /// The drag in flight in this window's sidebar. Kept here so compact mode can hold the sidebar open while it lasts.
    let drag = SidebarDragState()
    /// The workspace waiting for its delete confirmation; shown as an alert by the workspace switcher.
    var pendingWorkspaceDelete: Workspace?
    /// A sidebar action asked for from a menu; the sidebar runs it (asking for a name first when the action needs one).
    private(set) var actionRequest: SidebarActionRequest?
    private var actionSerial = 0
    func requestSidebarAction(_ action: SidebarAction, on item: SidebarItemID?) {
        actionSerial += 1
        actionRequest = SidebarActionRequest(serial: actionSerial, action: action, item: item)
    }
    /// Bumped to ask the sidebar list for the keyboard focus (compact mode's Tab).
    private(set) var sidebarFocusRequest = 0
    func requestSidebarFocus() { sidebarFocusRequest += 1 }
    /// Non-nil while the command bar is open.
    private(set) var commandBar: CommandBarModel?
    /// False when the bar closed by presenting a sheet, alert or popover, which must keep the focus it takes.
    @ObservationIgnored private(set) var returnsFocusToList = true
    /// Opens a window like ⌘N. Set by the window controller.
    @ObservationIgnored var newWindow: () -> Void = {}
    /// Opens the Arc import like File ▸ Import from Arc…. Set by the window controller.
    @ObservationIgnored var importFromArc: () -> Void = {}

    /// Opens (or reopens in another mode) the command bar from the window's current state.
    func openCommandBar(_ mode: CommandBarMode, for model: BrowserWindowModel) {
        commandBar = CommandBarModel(
            mode: mode, candidates: model.commandCandidates(), currentURL: model.selectedTab?.url,
            currentWorkspaceID: model.snapshot.workspace.id, searchEngine: model.searchEngine,
            currentTabID: model.selectedTabID
        )
        returnsFocusToList = true
    }

    /// Shows the archive the way `ArchivePresentation` says for what asked: a mouse click toggles the popover, anything else opens the sheet.
    func openArchive(_ trigger: ArchiveTrigger) {
        switch ArchivePresentation.presentation(for: trigger) {
        case .popover: showArchive.toggle()
        case .sheet:
            showArchive = false
            showArchiveSheet = true
        }
    }

    /// Clears every sheet-driving state, so SwiftUI dismisses what it presents. Used when the app quits.
    func dismissAllSheets() {
        sheet = nil
        workspaceEditor = nil
        showNewProfile = false
        pendingWorkspaceDelete = nil
        showArchiveSheet = false
        showArchive = false
        commandBar = nil
    }

    func closeCommandBar() {
        guard commandBar != nil else { return } // nothing open: a late close must not reset focus a panel-presenting close just gave up
        returnsFocusToList = true
        commandBar = nil
    }

    /// Runs the bar's selected row. The bar closes unless it needs an engine choice; an outcome the window cannot handle is handled here.
    func activate(in model: BrowserWindowModel) {
        guard let bar = commandBar else { return }
        switch bar.activate(in: model) {
        case .stay: return
        case .close(let outcome):
            returnsFocusToList = !Self.presentsPanel(outcome)
            commandBar = nil
            handle(outcome)
        }
    }

    private static func presentsPanel(_ outcome: CommandOutcome) -> Bool {
        switch outcome {
        case .newWorkspace, .newProfile, .showArchive, .showArcImport: true
        default: false
        }
    }

    private func handle(_ outcome: CommandOutcome) {
        switch outcome {
        case .done, .chooseSearchEngine: break // the bar keeps itself open for an engine choice and never reports it as a close
        case .showArcImport: importFromArc()
        case .showArchive: openArchive(.command)
        case .newWindow: newWindow()
        case .newWorkspace: workspaceEditor = .create
        case .newProfile: showNewProfile = true
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// A workspace action on `workspace` (its button's menu, or the Workspaces menu for the current one): Edit opens the editor, Delete asks
    /// for confirmation, the moves write through the model.
    func perform(_ action: WorkspaceAction, on workspace: Workspace, in model: BrowserWindowModel) {
        switch action {
        case .edit: workspaceEditor = .edit(workspace)
        case .delete: pendingWorkspaceDelete = workspace
        case .moveLeft, .moveRight:
            let ids = model.workspaces.map(\.id)
            guard let index = ids.firstIndex(of: workspace.id),
                  let target = WorkspaceMenus.moveTarget(action, index: index, ids: ids) else { return }
            model.moveWorkspace(workspace.id, after: target.afterID)
        }
    }
}

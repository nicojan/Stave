import AppKit
import Observation
import StaveCore

/// Window-level UI requests that menus, the command bar and the sidebar make of one another: the workspace editor, the archive popover,
/// the new-profile prompt and the command bar itself. Holds presentation state only; every rule is in StaveCore.
@MainActor @Observable
final class SidebarPresenter {
    var workspaceEditor: WorkspaceEditorMode?
    var showArchive = false
    var showNewProfile = false
    /// The first-run or Arc import sheet on this window, if any.
    var sheet: WindowSheet?
    /// The drag in flight in this window's sidebar. Kept here so compact mode can hold the sidebar open while it lasts.
    let drag = SidebarDragState()
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

    func closeCommandBar() {
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
        case .showArchive: showArchive = true
        case .newWindow: newWindow()
        case .newWorkspace: workspaceEditor = .create
        case .newProfile: showNewProfile = true
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

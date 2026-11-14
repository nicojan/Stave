import SwiftUI
import StaveCore

/// Move to Workspace for one tab: the targets (`SidebarMenus.moveTargets`), each item's symbol, and what choosing one does. The row context
/// menu and Tab ▸ Move to Workspace both show it, so they offer the same list.
struct MoveToWorkspaceMenu {
    let targets: [TabMoveTarget]
    let symbol: (TabMoveTarget) -> String?
    let perform: (TabMoveTarget) -> Void

    static var none: MoveToWorkspaceMenu { MoveToWorkspaceMenu(targets: [], symbol: { _ in nil }, perform: { _ in }) }
}

/// The items of a Move to Workspace menu: each target's title, with its workspace's symbol when the icon is one.
struct MoveToWorkspaceItems: View {
    let menu: MoveToWorkspaceMenu
    var isDisabled = false

    var body: some View {
        ForEach(menu.targets, id: \.self) { target in
            Group {
                if let symbol = menu.symbol(target) {
                    Button { menu.perform(target) } label: { Label(target.title, systemImage: symbol) }
                } else {
                    Button(target.title) { menu.perform(target) }
                }
            }
            .disabled(isDisabled)
        }
    }
}

/// One `SidebarMenus` list drives both the context menu and the VoiceOver actions, so they always match.
extension View {
    /// The context menu for `actions`, then a Move to Workspace submenu when `moves` has targets.
    func sidebarContextMenu(
        _ actions: [SidebarAction], moves: MoveToWorkspaceMenu = .none, perform: @escaping (SidebarAction) -> Void
    ) -> some View {
        contextMenu {
            ForEach(actions, id: \.self) { action in
                Button { perform(action) } label: { Label(action.title, systemImage: action.symbol) }
            }
            if !moves.targets.isEmpty {
                Divider()
                Menu(PageChromeText.moveToWorkspaceMenu) { MoveToWorkspaceItems(menu: moves) }
            }
        }
    }

    /// The VoiceOver actions for `actions` and `moves`, named as the menu items are.
    func sidebarAccessibilityActions(
        _ actions: [SidebarAction], moves: MoveToWorkspaceMenu = .none, perform: @escaping (SidebarAction) -> Void
    ) -> some View {
        accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
            ForEach(moves.targets, id: \.self) { target in
                Button(target.title) { moves.perform(target) }
            }
        }
    }

    /// Both, on the same element (Essentials tiles and the Pinned header).
    func sidebarActions(_ actions: [SidebarAction], perform: @escaping (SidebarAction) -> Void) -> some View {
        sidebarContextMenu(actions, perform: perform).sidebarAccessibilityActions(actions, perform: perform)
    }
}

extension Color {
    /// `#RRGGBB`; anything else is the system grey, so a bad stored value still draws. The parsing rule is `HexColor` in StaveCore.
    init(hex: String) {
        guard let rgb = HexColor.rgb(hex) else {
            self = .gray
            return
        }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

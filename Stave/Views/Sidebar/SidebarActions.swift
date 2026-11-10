import SwiftUI
import StaveCore

/// One `SidebarMenus` list drives both the context menu and the VoiceOver actions, so they always match.
extension View {
    /// The context menu for `actions`.
    func sidebarContextMenu(_ actions: [SidebarAction], perform: @escaping (SidebarAction) -> Void) -> some View {
        contextMenu {
            ForEach(actions, id: \.self) { action in
                Button { perform(action) } label: { Label(action.title, systemImage: action.symbol) }
            }
        }
    }

    /// The VoiceOver actions for `actions`, named as the menu items are.
    func sidebarAccessibilityActions(_ actions: [SidebarAction], perform: @escaping (SidebarAction) -> Void) -> some View {
        accessibilityActions {
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action) }
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

import SwiftUI
import StaveCore

/// One `SidebarMenus` list drives both the context menu and the VoiceOver actions, so they always match.
private struct SidebarActionsModifier: ViewModifier {
    let actions: [SidebarAction]
    let perform: (SidebarAction) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                ForEach(actions, id: \.self) { action in
                    Button { perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                }
            }
            .accessibilityActions {
                ForEach(actions, id: \.self) { action in
                    Button(action.title) { perform(action) }
                }
            }
    }
}

extension View {
    func sidebarActions(_ actions: [SidebarAction], perform: @escaping (SidebarAction) -> Void) -> some View {
        modifier(SidebarActionsModifier(actions: actions, perform: perform))
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

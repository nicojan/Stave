import SwiftUI

@main
struct StaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Windows are AppKit-managed (see AppDelegate); SwiftUI only needs a scene, which also hosts the menu commands.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Window") { delegate.newWindow() }
                        .keyboardShortcut("n", modifiers: .command)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Close Tab") { delegate.closeSelectedTab() }
                        .keyboardShortcut("w", modifiers: .command)
                    Button("Close Window") { delegate.closeWindow() }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }
    }
}

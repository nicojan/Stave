import Foundation

/// The window title (hidden, but used by the Window menu and VoiceOver): the selected tab's title, else the workspace name.
public enum WindowTitle {
    public static func title(selectedTab: Tab?, workspaceName: String) -> String {
        selectedTab.map(DisplayText.title(for:)) ?? workspaceName
    }
}

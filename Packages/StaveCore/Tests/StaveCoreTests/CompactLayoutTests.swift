import Testing
@testable import StaveCore

struct CompactLayoutTests {
    private let sidebar = 260.0
    private let divider = 1.0

    @Test func normalModeRunsTheContentUnderTheTitleBarBesideTheSidebar() {
        #expect(CompactLayout.contentUnderTitleBar(isCompact: false))
        #expect(CompactLayout.contentLeading(isCompact: false, sidebarWidth: sidebar, dividerWidth: divider) == 261)
    }

    /// Nico, 2026-11-09: compact mode hides only the sidebar. The title bar stays a bar of its own, so the traffic lights never sit over
    /// the page, and the content takes the full width below it.
    @Test func compactModeKeepsTheTitleBarAndTheFullWidth() {
        #expect(!CompactLayout.contentUnderTitleBar(isCompact: true))
        #expect(CompactLayout.contentLeading(isCompact: true, sidebarWidth: sidebar, dividerWidth: divider) == 0)
    }

    /// Under the title bar the sidebar clears the traffic lights (28 pt); below a real title bar it needs only a margin.
    @Test func theSidebarClearsTheTrafficLightsOnlyWhenItRunsUnderThem() {
        #expect(CompactLayout.sidebarTop(isCompact: false) == 28)
        #expect(CompactLayout.sidebarTop(isCompact: true) == 8)
    }
}

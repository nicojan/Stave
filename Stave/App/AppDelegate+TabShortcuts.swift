import AppKit
import StaveCore
import StaveWeb

/// The tab commands of decision 16 on the key window: ⌘1–9 and ⌃Tab (question 17), ⇧⌘T, ⌘D (question 18) and ⌥⌘L, plus the hidden
/// keys (⌘= for Zoom In, ⇧⌘] and ⇧⌘[ for the next and previous tab). Each obeys the sheet gate, as the menu items do.
extension AppDelegate {
    /// ⌘1–⌘8 the nth tab in sidebar order, ⌘9 the last; in a private window, of its list. Returns whether it selected a tab, so the key
    /// monitor consumes the key only when it did something.
    @discardableResult
    func selectTab(number: Int) -> Bool {
        if let keyPrivate {
            return keyPrivate.window.attachedSheet == nil && keyPrivate.model.selectTab(number: number)
        }
        guard let controller = keyController, !keyWindowIsBusy(for: .selectTab) else { return false }
        return controller.model.selectTab(number: number)
    }

    /// ⌃Tab (+1) and ⌃⇧Tab (-1), wrapping.
    func selectAdjacentTab(_ delta: Int) {
        if let keyPrivate {
            if keyPrivate.window.attachedSheet == nil { keyPrivate.model.selectAdjacentTab(delta) }
            return
        }
        guard let controller = keyController, !keyWindowIsBusy(for: .selectTab) else { return }
        controller.model.selectAdjacentTab(delta)
    }

    /// ⇧⌘T: the newest archived tab of the key window's workspace comes back, selected. A private window has no archive.
    func reopenLastClosedTab() {
        guard keyPrivate == nil, let controller = keyController, !keyWindowIsBusy(for: .reopenClosedTab) else { return }
        controller.model.reopenLastClosed()
    }

    /// ⌘D: pins the selected regular tab, only where the menu rule allows it now (`PageMenuState.canPinSelected`).
    func pinSelectedTab() {
        guard keyPrivate == nil, let controller = keyController, let page = controller.shownPage else { return }
        let rule = PageMenuState.from(
            status: Self.summary(of: page, section: controller.model.selectedSection), sheetOpen: isBusy(controller),
            historyShown: controller.model.isShowingHistory
        )
        guard rule.canPinSelected else { return }
        controller.model.pinSelectedTab()
    }

    /// ⌥⌘L: opens or closes the key window's downloads popover while it has downloads.
    func showDownloads() {
        guard let environment else { return }
        if let keyPrivate {
            let state = TabShortcutMenuState.from(
                busy: keyPrivate.window.attachedSheet != nil, isPrivate: true, tabCount: keyPrivate.model.tabs.count,
                hasDownloads: environment.downloads.hasItems(for: .privateWindow(keyPrivate.windowID))
            )
            if state.canShowDownloads { keyPrivate.presenter.showDownloads.toggle() }
            return
        }
        guard let controller = keyController else { return }
        let state = TabShortcutMenuState.from(
            busy: isBusy(controller), isPrivate: false, tabCount: controller.model.tabsInSidebarOrder.count,
            hasDownloads: environment.downloads.hasItems(for: .profile(controller.model.snapshot.profile.id))
        )
        if state.canShowDownloads { controller.sidebarPresenter.showDownloads.toggle() }
    }

    /// The table's hidden entries (⌘=, ⇧⌘], ⇧⌘[ and ⌘1–9; a SwiftUI menu item takes one key, and no menu lists ⌘1–9) are caught before the
    /// menus and sent to the same command. A key is consumed only when its gate is open and the command acts; otherwise it goes on as usual.
    func installHiddenShortcuts() {
        guard alternateKeyMonitor == nil else { return }
        alternateKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let entry = StandardShortcutKeys.hiddenEntry(for: event), self.runHidden(entry) else { return event }
            return nil
        }
    }

    private func runHidden(_ entry: ShortcutEntry) -> Bool {
        guard entry.isEnabled(busy: menuState.isBusy) else { return false }
        switch entry.command {
        case .zoomIn where menuState.pageMenu.canZoomIn: zoomIn()
        case .nextTab where menuState.tabKeys.canSelectTab: selectAdjacentTab(1)
        case .previousTab where menuState.tabKeys.canSelectTab: selectAdjacentTab(-1)
        case .selectTab(let number): return selectTab(number: number)
        default: return false
        }
        return true
    }
}

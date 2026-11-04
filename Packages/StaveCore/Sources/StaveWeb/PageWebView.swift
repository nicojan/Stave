import AppKit
import Foundation
import StaveCore
import WebKit

/// A page's web view: WebKit's, plus "Open Link in New Tab" in the link menu (walkthrough fix 4).
///
/// WebKit doesn't say which link a menu is for, so the new item runs WebKit's own "Open Link in New Window" (which asks the UI delegate
/// for a new web view with the link's request) and records the choice; `PageDelegate` then opens the link as a background tab instead.
public final class PageWebView: WKWebView {
    static let openInNewWindowItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    static let openInNewTabItem = NSUserInterfaceItemIdentifier("StaveOpenLinkInNewTab")
    /// How long a menu choice waits for WebKit's new-view request; after that a new view is the page's own (`window.open`).
    static let newTabChoiceLifetime: TimeInterval = 2

    /// Called on a click or key press in the page, and on reload, back and forward (which the app's commands call): the user acting on it.
    var onUserAction: (() -> Void)?
    /// The host's clock, so tests can age a choice.
    var now: () -> Date = Date.init
    private var newTabChosenAt: Date?

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // A new menu: any earlier choice WebKit never acted on is dead.
        newTabChosenAt = nil
        guard !menu.items.contains(where: { $0.identifier == Self.openInNewTabItem }),
              let index = menu.items.firstIndex(where: { $0.identifier == Self.openInNewWindowItem }) else { return }
        let item = NSMenuItem(title: PageText.openLinkInNewTab, action: #selector(openLinkInNewTab(_:)), keyEquivalent: "")
        item.identifier = Self.openInNewTabItem
        item.target = self
        let newWindow = menu.items[index]
        item.representedObject = newWindow
        item.isEnabled = newWindow.isEnabled
        item.isHidden = newWindow.isHidden
        menu.insertItem(item, at: index)
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let newWindow = sender.representedObject as? NSMenuItem, let action = newWindow.action else { return }
        newTabChosenAt = now()
        // WebKit's target reads the item it built (its tag and represented object), so that item is the sender.
        if !NSApplication.shared.sendAction(action, to: newWindow.target, from: newWindow) { newTabChosenAt = nil }
    }

    // MARK: The user acting on the page

    override public func mouseDown(with event: NSEvent) {
        onUserAction?()
        super.mouseDown(with: event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        onUserAction?()
        super.rightMouseDown(with: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        onUserAction?()
        super.otherMouseDown(with: event)
    }

    override public func keyDown(with event: NSEvent) {
        onUserAction?()
        super.keyDown(with: event)
    }

    @discardableResult override public func reload() -> WKNavigation? {
        onUserAction?()
        return super.reload()
    }

    @discardableResult override public func reloadFromOrigin() -> WKNavigation? {
        onUserAction?()
        return super.reloadFromOrigin()
    }

    @discardableResult override public func goBack() -> WKNavigation? {
        onUserAction?()
        return super.goBack()
    }

    @discardableResult override public func goForward() -> WKNavigation? {
        onUserAction?()
        return super.goForward()
    }

    // MARK: The link menu

    /// Whether the new view WebKit is asking for comes from "Open Link in New Tab". True at most once per choice.
    func takeNewTabChoice() -> Bool {
        defer { newTabChosenAt = nil }
        guard let chosen = newTabChosenAt else { return false }
        return now().timeIntervalSince(chosen) <= Self.newTabChoiceLifetime
    }
}

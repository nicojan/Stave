import AppKit
import Foundation
import StaveCore
import WebKit

/// A page's web view: WebKit's, plus "Open Link in New Tab" in the link menu (walkthrough fix 4), and "Open Link in New Window" opening a
/// real window.
///
/// WebKit doesn't say which link a menu is for, so both items run WebKit's own "Open Link in New Window" (which asks the UI delegate for a
/// new web view with the link's request) and record the choice; `PageDelegate` then opens the link as a background tab, or in a new window,
/// instead. WebKit's own item is retargeted to this view, which records the choice and forwards to WebKit's original target and action.
public final class PageWebView: WKWebView {
    static let openInNewWindowItem = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
    static let openInNewTabItem = NSUserInterfaceItemIdentifier("StaveOpenLinkInNewTab")
    /// How long a menu choice waits for WebKit's new-view request; after that a new view is the page's own (`window.open`).
    static let newTabChoiceLifetime: TimeInterval = 2

    /// What the link menu's last choice asked for.
    enum LinkMenuChoice: Equatable { case newTab, newWindow }

    /// Called on a click or key press in the page, and on reload, back and forward (which the app's commands call): the user acting on it.
    var onUserAction: (() -> Void)?
    /// The host's clock, so tests can age a choice.
    var now: () -> Date = Date.init
    private var choice: (kind: LinkMenuChoice, at: Date)?
    /// WebKit's own "Open Link in New Window" target and action, kept while its item points at this view instead.
    private weak var webKitTarget: AnyObject?
    private var webKitAction: Selector?

    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // A new menu: any earlier choice WebKit never acted on is dead.
        choice = nil
        guard !menu.items.contains(where: { $0.identifier == Self.openInNewTabItem }),
              let index = menu.items.firstIndex(where: { $0.identifier == Self.openInNewWindowItem }) else { return }
        let newWindow = menu.items[index]
        // Keep WebKit's target and action, and point its item at this view so that choosing it is recorded. Not if it already points here.
        if newWindow.target !== self {
            webKitTarget = newWindow.target
            webKitAction = newWindow.action
            newWindow.target = self
            newWindow.action = #selector(openLinkInNewWindow(_:))
        }
        let item = NSMenuItem(title: PageText.openLinkInNewTab, action: #selector(openLinkInNewTab(_:)), keyEquivalent: "")
        item.identifier = Self.openInNewTabItem
        item.target = self
        item.representedObject = newWindow
        item.isEnabled = newWindow.isEnabled
        item.isHidden = newWindow.isHidden
        menu.insertItem(item, at: index)
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let newWindow = sender.representedObject as? NSMenuItem else { return }
        forward(newWindow, as: .newTab)
    }

    @objc private func openLinkInNewWindow(_ sender: NSMenuItem) {
        forward(sender, as: .newWindow)
    }

    /// Records the choice and runs WebKit's own action. WebKit's target reads the item it built (its tag and represented object), so that
    /// item is the sender.
    private func forward(_ webKitItem: NSMenuItem, as kind: LinkMenuChoice) {
        guard let action = webKitAction else { return }
        choice = (kind, now())
        if !NSApplication.shared.sendAction(action, to: webKitTarget, from: webKitItem) { choice = nil }
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

    /// What the link menu chose, when the new view WebKit is asking for comes from it. At most once per choice.
    func takeLinkMenuChoice() -> LinkMenuChoice? {
        defer { choice = nil }
        guard let choice, now().timeIntervalSince(choice.at) <= Self.newTabChoiceLifetime else { return nil }
        return choice.kind
    }
}

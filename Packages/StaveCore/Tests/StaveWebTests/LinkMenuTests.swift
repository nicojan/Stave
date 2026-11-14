import AppKit
import StaveCore
import Testing
import WebKit

@testable import StaveWeb

/// Stands in for WebKit's menu target: records each "Open Link in New Window" and the item sent with it (WebKit reads that item's tag
/// and represented object, so it must be WebKit's own item).
@MainActor
final class FakeMenuTarget: NSObject {
    var senders: [AnyObject?] = []
    @objc func choose(_ sender: Any?) { senders.append(sender as AnyObject?) }
}

/// "Open Link in New Tab" and "Open Link in New Window" in a page's link menu (walkthrough fix 4; the window one opens a real window).
extension PageDelegateTests {
    /// A link menu as WebKit builds it: the items carry WebKit's identifiers, and "Open Link in New Window" goes to WebKit's target.
    func linkMenu(target: FakeMenuTarget) -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        open.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        let newWindow = NSMenuItem(title: "Open Link in New Window", action: #selector(FakeMenuTarget.choose(_:)), keyEquivalent: "")
        newWindow.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        newWindow.target = target
        let copy = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")
        copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
        menu.items = [open, newWindow, copy]
        return menu
    }

    func rightClick() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func linkMenuOffersOpenLinkInNewTab() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let menu = linkMenu(target: FakeMenuTarget())
        page.webView.willOpenMenu(menu, with: try rightClick())
        #expect(menu.items.map(\.title) == ["Open Link", PageText.openLinkInNewTab, "Open Link in New Window", "Copy Link"])
        // Asked twice for the same menu, it adds the item once.
        page.webView.willOpenMenu(menu, with: try rightClick())
        #expect(menu.items.filter { $0.title == PageText.openLinkInNewTab }.count == 1)
        host.close(page.tabID)
    }

    @Test func menuWithoutALinkGetsNoNewTabItem() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let menu = NSMenu()
        menu.items = [NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")]
        page.webView.willOpenMenu(menu, with: try rightClick())
        #expect(menu.items.map(\.title) == ["Copy"])
        host.close(page.tabID)
    }

    /// Opens the menu on `page` and chooses "Open Link in New Tab".
    func chooseOpenInNewTab(on webView: WKWebView, target: FakeMenuTarget = FakeMenuTarget()) throws -> NSMenu {
        let menu = linkMenu(target: target)
        webView.willOpenMenu(menu, with: try rightClick())
        let item = try #require(menu.items.first { $0.title == PageText.openLinkInNewTab })
        let action = try #require(item.action)
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        return menu
    }

    @Test func openLinkInNewTabOpensABackgroundTab() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let target = FakeMenuTarget()
        let menu = try chooseOpenInNewTab(on: page.webView, target: target)
        // WebKit's own "Open Link in New Window" runs, sent from WebKit's item, and asks for a new web view.
        let newWindow = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" })
        #expect(target.senders.count == 1)
        #expect(target.senders.first.flatMap { $0 } === newWindow)
        let made = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/n", type: .other), windowFeatures: FakeFeatures())
        // Opened as ⌘-click opens a link: a fresh background tab the app makes; WebKit gets no view.
        #expect(made == nil)
        #expect(events.linkedTabs == [.init(opener: page.tabID, url: "https://example.com/n", select: false, hasWebView: false)])
        // The choice is used once: the next new window opens as before (a selected tab).
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/m", type: .other), windowFeatures: FakeFeatures())
        #expect(events.linkedTabs.last == .init(opener: page.tabID, url: "https://example.com/m", select: true, hasWebView: true))
        host.close(page.tabID)
    }

    /// Opens the menu on `webView` and chooses WebKit's own "Open Link in New Window", as the user does.
    func chooseOpenInNewWindow(on webView: WKWebView, target: FakeMenuTarget = FakeMenuTarget()) throws -> NSMenu {
        let menu = linkMenu(target: target)
        webView.willOpenMenu(menu, with: try rightClick())
        let item = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" })
        let action = try #require(item.action)
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        return menu
    }

    @Test func openLinkInNewWindowOpensAWindowNotATab() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let target = FakeMenuTarget()
        let menu = try chooseOpenInNewWindow(on: page.webView, target: target)
        // WebKit's own item still runs, once, sent from WebKit's item (it reads the item's tag and represented object).
        let newWindow = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" })
        #expect(target.senders.count == 1)
        #expect(target.senders.first.flatMap { $0 } === newWindow)
        let made = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/w", type: .other), windowFeatures: FakeFeatures())
        // The app makes the window and its page; WebKit gets no view.
        #expect(made == nil)
        #expect(events.newWindowLinks.map(\.url) == ["https://example.com/w"])
        #expect(events.newWindowLinks.first?.opener == page.tabID)
        #expect(events.linkedTabs.isEmpty)
        // The choice is used once: the next new window is the page's own, as before (a selected tab).
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/m", type: .other), windowFeatures: FakeFeatures())
        #expect(events.newWindowLinks.count == 1)
        #expect(events.linkedTabs.last == .init(opener: page.tabID, url: "https://example.com/m", select: true, hasWebView: true))
        host.close(page.tabID)
    }

    @Test func menuOpenedTwiceStillForwardsTheNewWindowChoiceToWebKitOnce() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let target = FakeMenuTarget()
        let menu = linkMenu(target: target)
        page.webView.willOpenMenu(menu, with: try rightClick())
        page.webView.willOpenMenu(menu, with: try rightClick())
        let item = try #require(menu.items.first { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" })
        NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(target.senders.count == 1)
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/w", type: .other), windowFeatures: FakeFeatures())
        #expect(events.newWindowLinks.count == 1)
        // The new tab item still reaches WebKit's own item, and opens a tab, not a window.
        let tabItem = try #require(menu.items.first { $0.title == PageText.openLinkInNewTab })
        NSApplication.shared.sendAction(try #require(tabItem.action), to: tabItem.target, from: tabItem)
        #expect(target.senders.count == 2)
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/t", type: .other), windowFeatures: FakeFeatures())
        #expect(events.newWindowLinks.count == 1)
        #expect(events.linkedTabs.last == .init(opener: page.tabID, url: "https://example.com/t", select: false, hasWebView: false))
        host.close(page.tabID)
    }

    @Test func newWindowChoiceExpiresAndRefusedLinksOpenNothing() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewWindow(on: page.webView)
        clock.date += 5
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/later", type: .other), windowFeatures: FakeFeatures())
        #expect(events.newWindowLinks.isEmpty)
        #expect(events.linkedTabs.count == 1)

        _ = try chooseOpenInNewWindow(on: page.webView)
        let made = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("file:///etc/hosts", type: .other), windowFeatures: FakeFeatures())
        #expect(made == nil)
        #expect(events.newWindowLinks.isEmpty)
        #expect(events.linkedTabs.count == 1)
        host.close(page.tabID)
    }

    @Test func clickedBlankTargetLinkLeavesTheNewWindowChoiceToo() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewWindow(on: page.webView)
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/blank"), windowFeatures: FakeFeatures())
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/w", type: .other), windowFeatures: FakeFeatures())
        #expect(events.linkedTabs == [.init(opener: page.tabID, url: "https://example.com/blank", select: true, hasWebView: true)])
        #expect(events.newWindowLinks.map(\.url) == ["https://example.com/w"])
        host.close(page.tabID)
    }

    @Test func clickedBlankTargetLinkLeavesTheChoiceForTheMenusRequest() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewTab(on: page.webView)
        // A clicked target=_blank link arriving first is a link click, not the menu's request.
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/blank"), windowFeatures: FakeFeatures())
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/n", type: .other), windowFeatures: FakeFeatures())
        #expect(events.linkedTabs == [
            .init(opener: page.tabID, url: "https://example.com/blank", select: true, hasWebView: true),
            .init(opener: page.tabID, url: "https://example.com/n", select: false, hasWebView: false),
        ])
        host.close(page.tabID)
    }

    @Test func newTabChoiceLastsTwoSeconds() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewTab(on: page.webView)
        clock.date += PageWebView.newTabChoiceLifetime
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/n", type: .other), windowFeatures: FakeFeatures())
        #expect(events.linkedTabs.last?.select == false)
        host.close(page.tabID)
    }

    @Test func staleNewTabChoiceIsIgnored() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewTab(on: page.webView)
        // WebKit never asked for the view (say the link was a script); a page's later window.open is not a menu choice.
        clock.date += 5
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/later", type: .other), windowFeatures: FakeFeatures())
        #expect(events.linkedTabs == [.init(opener: page.tabID, url: "https://example.com/later", select: true, hasWebView: true)])
        host.close(page.tabID)
    }

    @Test func aNewMenuDropsAnUnusedChoice() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewTab(on: page.webView)
        page.webView.willOpenMenu(NSMenu(), with: try rightClick())
        _ = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/w", type: .other), windowFeatures: FakeFeatures())
        #expect(events.linkedTabs.last?.select == true)
        host.close(page.tabID)
    }

    @Test func refusedLinkOpensNoTab() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        _ = try chooseOpenInNewTab(on: page.webView)
        let made = delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("file:///etc/hosts", type: .other), windowFeatures: FakeFeatures())
        #expect(made == nil)
        #expect(events.linkedTabs.isEmpty)
        host.close(page.tabID)
    }

    @Test func linkedTabsAndPopupsGetTheLinkMenuToo() throws {
        let host = makeHost()
        let page = host.page(for: request(), writer: writer)
        let delegate = try delegate(of: page)
        let tab = try #require(delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/c"), windowFeatures: FakeFeatures()))
        let popup = try #require(delegate.webView(page.webView, createWebViewWith: page.webView.configuration, for: FakeAction("https://example.com/p", type: .other), windowFeatures: FakeFeatures(width: 500)))
        #expect(events.popups.count == 1)
        for child in [tab, popup] {
            let menu = linkMenu(target: FakeMenuTarget())
            child.willOpenMenu(menu, with: try rightClick())
            #expect(menu.items.contains { $0.title == PageText.openLinkInNewTab })
        }
        host.close(page.tabID)
    }
}

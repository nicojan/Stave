import AppKit
import StaveCore
import UniformTypeIdentifiers

/// Links and HTML files from other apps (decision 7, question 14), File ▸ Open File… (decision 6, question 13), and the default-browser
/// button. Where a link lands is `ExternalOpen.route`'s call; this file only gathers its inputs and acts on the answer.
extension AppDelegate {
    /// Each URL in order: web addresses through the policy as `.typed`, HTML files through `.openedFile`, anything else (an over-long URL, a
    /// file that isn't HTML) as a tab showing the refused panel. Before launch completes they wait in `pendingLinks`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launchCompleted else {
            pendingLinks.enqueue(urls)
            return
        }
        for url in urls { openExternal(url) }
    }

    /// Opens the links that came while the saved windows were being restored, in arrival order.
    func openPendingLinks() {
        for url in pendingLinks.drain() { openExternal(url) }
    }

    private func openExternal(_ url: URL) {
        guard let environment, let controller = linkWindow(environment) else {
            reportUnopened([url])
            return
        }
        let opened: Bool
        switch ExternalOpen.classify(url) {
        case .web(let address): opened = controller.openInNewTab(.typed(address), origin: .externalApp)
        case .file(let file): opened = controller.openInNewTab(.file(file), origin: .externalApp)
        case .refused(let shown): opened = controller.openInNewTab(.refused(shown), origin: .externalApp)
        }
        guard opened else {
            reportUnopened([url])
            return
        }
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The browser window a link goes to, made when the route asks for a new one. Nil when there is nowhere to put it.
    private func linkWindow(_ environment: AppEnvironment) -> BrowserWindowController? {
        let store = environment.store
        let target: ExternalLinkTarget
        do {
            target = try store.setting(SettingKeys.externalLinkTarget)
        } catch {
            NSLog("Stave: could not read where links from other apps open: \(error)")
            target = .lastUsed
        }
        let ordered = controllersByRecency
        let windows = ordered.map {
            WindowSummary(windowID: $0.model.windowID, profileID: $0.model.snapshot.profile.id, workspaceID: $0.model.snapshot.workspace.id)
        }
        let workspaces: [(profileID: UUID, workspaceIDs: [UUID])]
        do {
            workspaces = try store.profiles().map { (profileID: $0.id, workspaceIDs: try store.workspaces(profileID: $0.id).map(\.id)) }
        } catch {
            NSLog("Stave: could not read the profiles for a link from another app: \(error)")
            return ordered.first
        }
        let last = environment.session.states.last ?? (try? store.restoredWindows().first) ?? nil
        let route = ExternalOpen.route(
            target: target, windows: windows, workspacesByProfile: workspaces,
            lastSession: last.map { (profileID: $0.profileID, workspaceID: $0.workspaceID) }
        )
        switch route {
        case .existing(let windowID, let switchTo)?:
            guard let controller = ordered.first(where: { $0.model.windowID == windowID }) else { return nil }
            if let switchTo { controller.model.switchWorkspace(to: switchTo) }
            return controller
        case .newWindow(let profileID, let workspaceID)?:
            let state = WindowState(profileID: profileID, workspaceID: workspaceID, selectedTabID: nil, frame: frontController?.cascadedFrame ?? "", sortIndex: 0)
            do {
                return try open(state, environment: environment)
            } catch {
                NSLog("Stave: could not open a window for a link from another app: \(error)")
                return nil
            }
        case nil:
            return nil
        }
    }

    /// Browser windows, most recently active first: front to back as AppKit orders them, then any it doesn't list (minimized), newest first.
    private var controllersByRecency: [BrowserWindowController] {
        let order = NSApp.orderedWindows
        let listed = controllers
            .compactMap { controller in order.firstIndex { $0 === controller.window }.map { (controller, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let unlisted = controllers.reversed().filter { controller in !listed.contains { $0 === controller } }
        return listed + unlisted
    }

    /// A link that has nowhere to open is named to the user, never dropped.
    private func reportUnopened(_ urls: [URL]) {
        guard let text = ExternalOpenText.unopenedLinks(urls.map(\.absoluteString)) else { return }
        NSLog("Stave: could not open \(urls.count) link(s) from another app")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ExternalOpenText.unopenedTitle
        alert.informativeText = text
        alert.addButton(withTitle: PageChromeText.okButton)
        alert.runModal()
    }

    // MARK: - File ▸ Open File…

    /// ⌘O: an HTML file in a new tab of the key private window, else of the front browser window, else of a window the link route makes.
    func openFile() {
        guard launchCompleted, !keyWindowIsBusy(for: .newWindow) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html] + [UTType("public.xhtml")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let privateWindow = keyPrivate
        let browserWindow = privateWindow == nil ? frontController : nil
        guard panel.runModal() == .OK, let file = panel.url else { return }
        if let privateWindow, !privateWindow.isClosed {
            privateWindow.openFile(file)
        } else if let browserWindow, !browserWindow.isClosed {
            browserWindow.openFile(file, origin: .commandBar)
        } else {
            openExternal(file)
        }
    }

    // MARK: - Default browser

    /// Settings' "Make Stave your default browser": macOS asks the user to confirm, and sets `https` with `http`. Never called otherwise.
    func makeDefaultBrowser() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { [weak self] error in
            if let error { NSLog("Stave: could not become the default browser: \(error)") }
            Task { @MainActor [weak self] in self?.refreshDefaultBrowser() }
        }
    }

    /// Reads whether macOS opens `http` links with this build (Debug and Release are told apart by bundle ID).
    func refreshDefaultBrowser() {
        let app = URL(string: "http://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        let isDefault = ExternalOpenText.isStaveDefault(defaultBundleID: app.flatMap { Bundle(url: $0)?.bundleIdentifier }, ownBundleID: Bundle.main.bundleIdentifier)
        if menuState.isDefaultBrowser != isDefault { menuState.isDefaultBrowser = isDefault }
    }

    /// The answer can change in System Settings or another browser while Stave runs: it is read again whenever Stave becomes active.
    func observeDefaultBrowser() {
        refreshDefaultBrowser()
        keyObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDefaultBrowser() }
        })
    }
}

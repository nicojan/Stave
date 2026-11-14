import AppKit
import StaveCore

/// Private windows: opening them (⇧⌘N and "Open Link in New Window" from one), the profile they take, and routing commands to the key one.
/// None of it is saved or restored.
extension AppDelegate {
    /// "Open Link in New Window" from a private window: a new private window beside it, with the link as its selected tab.
    func openPrivateWindow(forLink url: String, opener: UUID, from source: PrivateWindowController) {
        guard let environment, launchCompleted else { return }
        let controller = PrivateWindowController(
            environment: environment, profileID: source.profileID, near: source.window,
            onClose: { [weak self] closed in self?.privateWindowClosed(closed) }
        )
        privateControllers = privateControllers + [controller]
        controller.show()
        refreshWorkspaceMenu()
        if controller.openLinkedTab(opener: opener, url: url, select: true, webView: nil) == nil { controller.window.close() }
    }

    /// ⇧⌘N: a private window beside the front window. Opens with an empty tab list; nothing of it is saved. Like ⌘N, nothing while a
    /// sheet is up on the key window.
    func newPrivateWindow() {
        guard let environment, launchCompleted, !keyWindowIsBusy(for: .newWindow),
              let profileID = privateWindowProfileID(environment) else { return }
        let controller = PrivateWindowController(
            environment: environment, profileID: profileID, near: NSApp.keyWindow ?? frontController?.window,
            onClose: { [weak self] closed in self?.privateWindowClosed(closed) }
        )
        privateControllers = privateControllers + [controller]
        controller.show()
        controller.openCommandBar(.newTab)
        refreshWorkspaceMenu()
    }

    /// The profile a new private window belongs to (its throwaway session is shared with that profile's other private windows): the key
    /// private window's, a key pop-up's (that of its opener tab's window), else the front browser window's, else the default profile's.
    private func privateWindowProfileID(_ environment: AppEnvironment) -> UUID? {
        if let keyPrivate { return keyPrivate.profileID }
        if let key = NSApp.keyWindow, let popup = environment.popups.all.first(where: { $0.window === Self.rootWindow(of: key) }) {
            if let owner = privateControllers.first(where: { $0.owns(popup.id) }) { return owner.profileID }
            if let profileID = try? environment.store.profileID(forTab: popup.openerTabID) { return profileID }
        }
        if let front = frontController { return front.model.snapshot.profile.id }
        do {
            return try environment.store.ensureDefaultProfile().id
        } catch {
            NSLog("Stave: could not find a profile for a private window: \(error)")
            return nil
        }
    }

    private func privateWindowClosed(_ closed: PrivateWindowController) {
        privateControllers = privateControllers.filter { $0 !== closed }
        refreshWorkspaceMenu()
    }

    /// The private window that is key, or the one a key sheet (or a sheet on that sheet) is attached to.
    var keyPrivate: PrivateWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        let root = Self.rootWindow(of: key)
        return privateControllers.first { $0.window === root }
    }

    /// The page commands on the key private window. True when a private window is key, whether or not a sheet let the command run.
    func privatePageCommand(_ run: (PrivateWindowController) -> Void) -> Bool {
        guard let keyPrivate else { return false }
        if keyPrivate.window.attachedSheet == nil { run(keyPrivate) }
        return true
    }
}

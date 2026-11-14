import AppKit
import StaveCore

/// The launch's two outcomes besides the windows themselves: the first-run sheet, and the alerts for a launch that can't go on.
extension AppDelegate {
    /// Shows the first-run sheet on the first window of this launch, once, while the setting says it has not been completed.
    func presentFirstRunIfNeeded(_ environment: AppEnvironment) {
        guard let first = controllers.first else { return }
        do {
            guard try environment.store.setting(SettingKeys.firstRunCompleted) == false else { return }
        } catch {
            NSLog("Stave: could not read the first-run setting: \(error)")
            return
        }
        let offers: Bool
        do {
            offers = try ArcImportFlow.shouldOfferOnFirstRun(arcHome: environment.arcHome, store: environment.store)
        } catch {
            NSLog("Stave: could not check whether to offer the Arc import: \(error)")
            offers = false
        }
        first.sidebarPresenter.sheet = .firstRun(FirstRunRequest(offersArcImport: offers))
    }

    func completeFirstRun(on controller: BrowserWindowController, engine: SearchEngine, importFromArc: Bool) {
        guard let environment else { return }
        do {
            try environment.store.completeFirstRun(engine: engine)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = StoreErrorText.saveChoiceFailed
            alert.informativeText = StoreErrorText.message(for: error)
            alert.addButton(withTitle: PageChromeText.okButton)
            // The first-run sheet is still attached and cannot be dismissed, so the alert goes on top of it.
            alert.beginSheetModal(for: controller.window.attachedSheet ?? controller.window)
            return
        }
        environment.revision.bump()
        controller.sidebarPresenter.sheet = nil
        // The first-run sheet is still leaving, so the window is not "busy" for this hand-over.
        if importFromArc { importCoordinator?.open(on: controller, windowIsBusy: false) }
    }

    // MARK: - Failure

    func presentLaunchArgumentFailure(_ failure: LaunchArguments.Failure) {
        guard case .unusable(let flag) = failure else { return }
        let text = StoreErrorText.unusableLaunchArgument(flag)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = text.message
        alert.informativeText = [text.detail, ExternalOpenText.unopenedLinks(pendingLinks.failAll().map(\.absoluteString))]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: PageChromeText.quitButton)
        alert.runModal()
        NSApp.terminate(nil)
    }

    func presentOpenFailure(_ error: Error) {
        let text = StoreErrorText.openFailure(error)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = text.message
        // Links from other apps that were waiting for the launch are named here, never dropped (decision 7).
        let unopened = ExternalOpenText.unopenedLinks(pendingLinks.failAll().map(\.absoluteString))
        let detail = [text.detail, unopened].compactMap { $0 }.joined(separator: "\n\n")
        if !detail.isEmpty { alert.informativeText = detail }
        alert.addButton(withTitle: PageChromeText.quitButton)
        alert.runModal()
        NSApp.terminate(nil)
    }
}

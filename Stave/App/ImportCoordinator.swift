import AppKit
import StaveCore

/// Opens the Arc import: on this Mac's Arc when its file is there, else through a file picker. One import sheet at a time in the whole app;
/// asking again brings the open one forward. The picker starts in `arcHome` (the Debug override, or the real home), never anywhere else.
@MainActor
final class ImportCoordinator {
    private let environment: AppEnvironment
    private let controllers: () -> [BrowserWindowController]
    private var isPicking = false

    init(environment: AppEnvironment, controllers: @escaping () -> [BrowserWindowController]) {
        self.environment = environment
        self.controllers = controllers
    }

    private var activeController: BrowserWindowController? {
        controllers().first { $0.sidebarPresenter.sheet.isArcImport }
    }

    /// File ▸ Import from Arc…, the command bar row, and the first-run sheet's offer.
    func open(on controller: BrowserWindowController) {
        if let active = activeController { bringForward(active); return }
        guard !isPicking else { bringForward(controller); return }
        // Another sheet (the first-run screen) is up on this window: it must finish first.
        guard controller.sidebarPresenter.sheet == nil else { bringForward(controller); return }
        let home = environment.arcHome
        if ArcImporter.isAvailable(home: home) {
            present(.arcOnThisMac(home: home), on: controller)
        } else {
            pickFile(host: controller.window) { [weak self] url in self?.present(.pickedFile(url), on: controller) }
        }
    }

    /// "Choose Another File…": the picker over the open sheet, then the same session reads the picked file.
    func chooseAnotherFile(for session: ArcImportSession) {
        guard !isPicking, let controller = controllers().first(where: { $0.sidebarPresenter.sheet.session === session }) else { return }
        let host = controller.window.attachedSheet ?? controller.window
        pickFile(host: host) { [weak self] url in
            guard let self else { return }
            session.replace(flow: self.makeFlow(.pickedFile(url)), source: .pickedFile(url))
        }
    }

    private func present(_ source: ArcImportFlow.Source, on controller: BrowserWindowController) {
        let session = ArcImportSession(flow: makeFlow(source), source: source)
        controller.sidebarPresenter.sheet = .arcImport(session)
        bringForward(controller)
    }

    private func makeFlow(_ source: ArcImportFlow.Source) -> ArcImportFlow {
        ArcImportFlow(store: environment.store, revision: environment.revision, source: source)
    }

    private func bringForward(_ controller: BrowserWindowController) {
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pickFile(host: NSWindow, chosen: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = environment.arcHome
        panel.message = ArcImportSheetContent.panelMessage
        isPicking = true
        panel.beginSheetModal(for: host) { [weak self] response in
            let url = response == .OK ? panel.url : nil
            MainActor.assumeIsolated {
                self?.isPicking = false
                if let url { chosen(url) }
            }
        }
    }
}

extension WindowSheet? {
    var isArcImport: Bool { session != nil }
    var session: ArcImportSession? {
        if case .arcImport(let session)? = self { return session }
        return nil
    }
}

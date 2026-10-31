import Foundation

/// What the Arc import sheet shows for a phase: text, sections and buttons. The view renders it and maps each action to the flow.
public struct ArcImportSheetContent: Equatable {
    public enum Action: Equatable, Sendable { case cancel, start, confirmRepeat, done, chooseAnotherFile, close }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: Action
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var lines: [String]
    }

    public var title: String
    /// "From Arc on this Mac" or the picked file's name; only while ready.
    public var sourceDescription: String?
    public var showsUnpinnedTabsToggle: Bool
    public var notices: [String]
    public var showsProgress: Bool
    public var sections: [Section]
    /// The failure message, or the repeat warning.
    public var message: String?
    public var secondaryButton: Button?
    public var primaryButton: Button?
    /// False while importing: no Cancel, no Escape, no swipe-away.
    public var canDismiss: Bool

    public static let unpinnedTabsToggleTitle = "Also import unpinned tabs"
    public static let menuItemTitle = "Import from Arc…"
    public static let importingTitle = "Importing from Arc…"
    public static let arcOnThisMac = "From Arc on this Mac"
    public static let panelMessage = "Choose a copy of Arc's StorableSidebar.json"

    public static func sourceDescription(for source: ArcImportFlow.Source) -> String {
        switch source {
        case .arcOnThisMac: arcOnThisMac
        case .pickedFile(let url): url.lastPathComponent
        }
    }

    /// Decided from the phase alone, never from whether an earlier import exists.
    public init(phase: ArcImportFlow.Phase, source: ArcImportFlow.Source, locale: Locale = .current, timeZone: TimeZone = .current) {
        switch phase {
        case .ready:
            self.init(
                title: "Import from Arc", sourceDescription: Self.sourceDescription(for: source), showsUnpinnedTabsToggle: true,
                notices: [ArcImportCopy.loginsNotice, ArcImportCopy.keepACopy], showsProgress: false, sections: [], message: nil,
                secondaryButton: Button(title: "Cancel", action: .cancel), primaryButton: Button(title: "Import", action: .start), canDismiss: true
            )
        case .confirmRepeat(let previous):
            self.init(
                title: "Import from Arc again?", sourceDescription: nil, showsUnpinnedTabsToggle: false, notices: [], showsProgress: false,
                sections: [], message: ArcImportCopy.repeatWarning(previous: previous, locale: locale, timeZone: timeZone),
                secondaryButton: Button(title: "Cancel", action: .cancel), primaryButton: Button(title: "Import Again", action: .confirmRepeat), canDismiss: true
            )
        case .importing:
            self.init(
                title: Self.importingTitle, sourceDescription: nil, showsUnpinnedTabsToggle: false, notices: [], showsProgress: true,
                sections: [], message: nil, secondaryButton: nil, primaryButton: nil, canDismiss: false
            )
        case .finished(let summary):
            let sections = [
                Section(title: "Imported", lines: summary.imported),
                Section(title: "Changed to fit Stave", lines: summary.changed),
                Section(title: "Not imported", lines: summary.skipped),
            ].filter { !$0.lines.isEmpty }
            self.init(
                title: summary.headline, sourceDescription: nil, showsUnpinnedTabsToggle: false, notices: [], showsProgress: false,
                sections: sections, message: nil, secondaryButton: nil, primaryButton: Button(title: "Done", action: .done), canDismiss: true
            )
        case .failed(let text):
            self.init(
                title: "Couldn't import from Arc", sourceDescription: nil, showsUnpinnedTabsToggle: false, notices: [], showsProgress: false,
                sections: [], message: text,
                secondaryButton: Button(title: "Choose Another File…", action: .chooseAnotherFile),
                primaryButton: Button(title: "Close", action: .close), canDismiss: true
            )
        }
    }

    private init(
        title: String, sourceDescription: String?, showsUnpinnedTabsToggle: Bool, notices: [String], showsProgress: Bool,
        sections: [Section], message: String?, secondaryButton: Button?, primaryButton: Button?, canDismiss: Bool
    ) {
        self.title = title
        self.sourceDescription = sourceDescription
        self.showsUnpinnedTabsToggle = showsUnpinnedTabsToggle
        self.notices = notices
        self.showsProgress = showsProgress
        self.sections = sections
        self.message = message
        self.secondaryButton = secondaryButton
        self.primaryButton = primaryButton
        self.canDismiss = canDismiss
    }
}

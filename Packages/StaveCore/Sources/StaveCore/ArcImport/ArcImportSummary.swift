import Foundation

/// An `ArcImportReport` in plain words, for the import sheet to show verbatim.
public struct ArcImportSummary: Equatable, Sendable {
    public let headline: String
    public let imported: [String]
    public let changed: [String]
    public let skipped: [String]

    public init(report: ArcImportReport) {
        let counts = report.imported
        let lines = Self.importedLines(counts)
        self.headline = lines.isEmpty ? "Nothing was imported" : "Imported from Arc"
        self.imported = lines
        self.changed = report.flattened.map(Self.changedLine)
        self.skipped = report.skipped.map(Self.skippedLine)
    }

    private static func plural(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    private static func importedLines(_ c: ArcImportReport.Counts) -> [String] {
        let entries: [(Int, String, String)] = [
            (c.profiles, "new profile", "new profiles"),
            (c.workspaces, "workspace", "workspaces"),
            (c.folders, "folder", "folders"),
            (c.pinnedTabs, "pinned tab", "pinned tabs"),
            (c.essentials, "Essential", "Essentials"),
            (c.regularTabs, "tab", "tabs"),
        ]
        return entries.filter { $0.0 > 0 }.map { plural($0.0, $0.1, $0.2) }
    }

    private static func placeText(_ place: ArcImportReport.Place) -> String {
        switch place {
        case .space(let name): "in \(name)"
        case .favorites(nil): "in your Arc Favorites"
        case .favorites(let profile?): "in the Favorites of Arc's “\(profile)” profile"
        }
    }

    private static func changedLine(_ item: ArcImportReport.Flattened) -> String {
        switch item {
        case .folderTooDeep(let space, let folder):
            "“\(folder)” in \(space) was inside another folder. Stave folders go one level deep, so its tabs moved up a level."
        case .splitView(let place, let n):
            "A split view with \(n) tabs \(placeText(place)) became \(n) separate tabs."
        case .favoritesFolder(let folder):
            "The folder “\(folder)” in your Arc Favorites became separate Essentials."
        case .unpinnedFolder(let space, let folder):
            "The unpinned folder “\(folder)” in \(space) became separate tabs."
        }
    }

    private static func itemName(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "An item" }
        return "“\(title)”"
    }

    private static func skippedLine(_ item: ArcImportReport.Skipped) -> String {
        switch item {
        case .nonWebURL(let place, let title, let scheme):
            let address = scheme.isEmpty ? "no address" : "\(scheme):"
            return "\(itemName(title)) \(placeText(place)) isn't a web page (\(address)), so it wasn't imported."
        case .unsupportedItem(let place, let kind, let title):
            let what = switch kind {
            case "easel": "Easel"
            case "welcomeToArc": "welcome page"
            default: "item of kind “\(kind)”"
            }
            return "\(itemName(title)) \(placeText(place)) is an Arc \(what), which Stave doesn't have."
        case .unpinnedTabs(let space, let count):
            return "\(plural(count, "unpinned tab", "unpinned tabs")) in \(space) \(count == 1 ? "wasn't" : "weren't") imported. Turn on “Also import unpinned tabs” to bring them."
        case .unrecognizedProfile(let space):
            return "\(space) belonged to an Arc profile Stave couldn't identify, so it went into your first profile."
        case .duplicateItem(let count):
            return "\(plural(count, "item", "items")) appeared twice in Arc's file and \(count == 1 ? "was" : "were") imported once."
        case .unrecognizedFavoritesProfile:
            return "Some Arc Favorites belonged to a profile Stave couldn't identify, so they became Essentials in your first profile."
        case .spaceContentsMissing(let space):
            return "\(space) was imported, but Arc's file didn't say what was in it."
        }
    }
}

/// Fixed copy for the Arc import sheet.
public enum ArcImportCopy {
    public static let loginsNotice = "Logins, passwords and cookies can't be imported from Arc, so you'll sign in to sites again. If your passwords are in iCloud Keychain, the Passwords app can copy them for you. Passkeys will work in Stave once Apple approves it."

    public static let keepACopy = "Arc may stop opening on December 22, 2026. To import later, keep a copy of Arc's sidebar file: ~/Library/Application Support/Arc/StorableSidebar.json."

    public static func repeatWarning(previous: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return "You imported from Arc on \(formatter.string(from: previous)). Importing again adds a second copy of everything it brings in. Nothing you have now is changed."
    }

    public static let historyUnreadable = "Stave couldn't check whether you've imported from Arc before, so it didn't import."

    public static func errorMessage(for error: Error) -> String {
        switch error as? ArcImportError {
        case .fileTooLarge: "This file is over 64 MB, far larger than any Arc sidebar file, so Stave didn't open it."
        case .notJSON: "This isn't an Arc sidebar file. Stave couldn't read it as JSON."
        case .noSidebar: "This file doesn't contain an Arc sidebar."
        case .tooDeep: "This file's folders are nested deeper than Arc allows, so Stave didn't import it."
        case .unreadable: "Stave couldn't read this file."
        case nil: "Stave couldn't save the import. Nothing was changed."
        }
    }
}

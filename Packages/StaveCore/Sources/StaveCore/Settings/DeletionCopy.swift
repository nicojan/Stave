import Foundation

/// The questions Settings asks before deleting a profile or a container, and the refusal for a container still in use (decisions 18 and 19).
public enum DeletionCopy {
    public static let deleteButton = "Delete"
    public static let cancelButton = "Cancel"

    /// "Delete the profile “‹name›”? Its ‹n› workspaces, ‹n› tabs, its archive, history, downloads list and website data (cookies, sign-ins)
    /// will be deleted. This can't be undone. Stave's backups keep a copy for up to 3 days." The counts are the summary's own.
    public static func profileQuestion(_ summary: ProfileSummary, name: String) -> String {
        "Delete the profile “\(name)”? Its \(count(summary.workspaces, "workspace")), \(count(summary.tabs, "tab")), its archive, history, "
            + "downloads list and website data (cookies, sign-ins) will be deleted. This can't be undone. "
            + "Stave's backups keep a copy for up to 3 days."
    }

    /// The question before an unused container is deleted: what goes is its website data.
    public static func containerQuestion(name: String) -> String {
        "Delete the container “\(name)”? Its website data (cookies, sign-ins) will be deleted. This can't be undone."
    }

    /// "‹n› tabs still use “‹name›”. Close them or move them out first." The count is open and archived tabs together.
    public static func containerInUse(count: Int, name: String) -> String {
        let verb = count == 1 ? "still uses" : "still use"
        let rest = count == 1 ? "Close it or move it out first." : "Close them or move them out first."
        return "\(Self.count(count, "tab")) \(verb) “\(name)”. \(rest)"
    }

    /// Shown when the rows are gone but a website data store could not be removed from disk yet. Stave retries at its next launch.
    public static let websiteDataNotRemoved = "Stave deleted it, but couldn't remove all of its website data from this Mac yet. It will try again the next time Stave opens."

    /// Shown when the website data was removed but Stave couldn't write that down; the next launch checks it again.
    public static let websiteDataRemovedButNotNoted = "Stave deleted it and removed its website data, but couldn't note that down. It will check again the next time Stave opens."

    /// The confirmation before Remove All in Settings ▸ Websites.
    public static func removeAllWebsitesQuestion(profileName: String) -> String {
        "Remove everything Stave remembers about websites in the profile “\(profileName)”? Each site will ask again. This can't be undone."
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

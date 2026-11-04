import Darwin
import Foundation

/// Whether Stave can use the downloads folder.
enum FolderAccess: Sendable, Equatable {
    case readable
    /// macOS refused it (Privacy & Security ▸ Files and Folders): the only case System Settings can fix.
    case refused
    /// Missing, not a folder, or unreadable for another reason.
    case unavailable
}

/// Touches the downloads folder before WebKit is given a path in it (walkthrough fix 3).
///
/// The first time an app opens the downloads folder, macOS asks the user ("would like to access files in your Downloads folder") and
/// blocks the thread that opened it until they answer. Left to WebKit, that thread is the main thread: WebKit makes the folder's sandbox
/// extension when the destination is returned, and the whole app froze while the question was up. The check runs on its own queue
/// instead, so the question blocks only that queue, and downloads that arrive while it is up share the one check.
@MainActor
final class DownloadsFolderCheck {
    /// Seam for tests: the check itself, which may block for as long as macOS's question is up.
    var probe: @Sendable (URL) -> FolderAccess = DownloadsFolderCheck.open
    private var inFlight: (directory: URL, task: Task<FolderAccess, Never>)?
    private static let queue = DispatchQueue(label: "com.nicojan.Stave.downloads-folder")

    func access(_ directory: URL) async -> FolderAccess {
        if let inFlight, inFlight.directory == directory { return await inFlight.task.value }
        let probe = probe
        let task = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<FolderAccess, Never>) in
                Self.queue.async { continuation.resume(returning: probe(directory)) }
            }
        }
        inFlight = (directory, task)
        let access = await task.value
        if inFlight?.task == task { inFlight = nil }
        return access
    }

    /// Opens the folder and reads one entry: what makes macOS ask, without listing a large folder. Run on every download (no cache): a
    /// grant reset while Stave runs would otherwise bring the question back on the main thread.
    nonisolated static func open(_ directory: URL) -> FolderAccess {
        guard let folder = opendir(directory.path) else { return errno == EPERM ? .refused : .unavailable }
        _ = readdir(folder)
        closedir(folder)
        return .readable
    }
}

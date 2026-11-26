import AppKit
import SwiftUI
import StaveCore

/// The bottom bar's downloads button: shown while the window's profile has downloads, opening the list as a popover.
struct DownloadsButton: View {
    let downloads: DownloadList
    let owner: DownloadOwner
    /// Kept by the window's presenter, so View ▸ Show Downloads (⌥⌘L) opens the same popover.
    @Binding var showing: Bool

    var body: some View {
        // The flag outlives the button (Clear empties the list, a profile switch changes the owner), so it is reset here: otherwise the
        // popover would reopen by itself the next time a download brought the button back. `hasItems` flips only when a row is added or removed.
        // A ZStack, not a Group: a Group's modifiers attach to its children, so with no button there'd be nothing to hold the onChange.
        ZStack {
            if downloads.hasItems(for: owner) {
                Button { showing.toggle() } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless)
                    .help(DownloadRowText.buttonLabel)
                    .accessibilityLabel(DownloadRowText.buttonLabel)
                    // Opens upward from the bottom bar and is capped to the window's height, so it stays inside the window (plan 3 recorded it
                    // hanging below the bottom edge when it opened sideways). One popover, one material.
                    .popover(isPresented: $showing, arrowEdge: .top) {
                        DownloadsPopover(downloads: downloads, owner: owner, maxHeight: Self.popoverMaxHeight())
                    }
            }
        }
        .onChange(of: downloads.hasItems(for: owner)) { _, hasItems in
            if !hasItems { showing = false }
        }
        .onChange(of: owner) { _, _ in showing = false }
    }
}

extension DownloadsButton {
    /// The list's tallest height: 360, or less when the window is short, leaving room for the bar and the title bar.
    static func popoverMaxHeight() -> CGFloat {
        let windowHeight = NSApp.keyWindow?.contentLayoutRect.height ?? 600
        return max(120, min(360, windowHeight - 120))
    }
}

/// This profile's downloads, newest first: each row's name, state and progress, with Cancel while it runs and Show in Finder once done;
/// Clear removes the rows that ended. Every label and enablement comes from `DownloadRowText`.
struct DownloadsPopover: View {
    let downloads: DownloadList
    let owner: DownloadOwner
    var maxHeight: CGFloat = 360

    /// The finished rows whose file is gone, found off the main thread (a file on a slow or unmounted volume must not stall the popover).
    @State private var missingFiles: Set<UUID> = []
    /// The rows the check has answered for. Show in Finder stays disabled for a row until then, so a missing file is never offered.
    @State private var checkedFiles: Set<UUID> = []

    private var items: [DownloadItem] { downloads.items(for: owner) }

    /// Changes when a row appears, ends or names another file, which is when the missing set must be looked at again.
    private var fileKey: [String] { items.map { "\($0.id)|\(DownloadRowText.finishedFile($0)?.path ?? "")" } }

    private func refreshMissingFiles() async {
        let snapshot = items
        let missing = await Task.detached(priority: .utility) {
            DownloadRowText.missingFileIDs(snapshot) { FileManager.default.fileExists(atPath: $0.path) }
        }.value
        missingFiles = missing
        checkedFiles = Set(snapshot.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(DownloadRowText.title).font(.headline)
                Spacer()
                Button(DownloadRowText.clearButton) { downloads.clearFinished(owner: owner) }
                    .disabled(!DownloadRowText.canClear(items))
                    .accessibilityLabel(DownloadRowText.clearLabel)
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in row(item) }
                }
                .padding(10)
            }
        }
        .frame(width: 320)
        .frame(minHeight: 80, maxHeight: maxHeight)
        // Opaque, so the list reads as one material where the popover crosses the sidebar's edge (translucent, it showed a seam: darker over the
        // sidebar, lighter over the page).
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: fileKey) { await refreshMissingFiles() }
    }

    private func row(_ item: DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filename).lineLimit(1).truncationMode(.middle)
            if case .running(let fraction) = item.state {
                if let fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel(item.filename)
                        .accessibilityValue(DownloadRowText.status(item))
                } else {
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel(item.filename)
                        .accessibilityValue(DownloadRowText.status(item))
                }
            }
            HStack {
                Text(DownloadRowText.status(item, missingFile: missingFiles.contains(item.id))).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if DownloadRowText.canCancel(item) {
                    Button(DownloadRowText.cancelButton) { downloads.cancel(item.id) }
                        .controlSize(.small)
                        .accessibilityLabel(DownloadRowText.cancelLabel(item))
                }
                if let file = DownloadRowText.finishedFile(item) {
                    Button(DownloadRowText.showInFinderButton) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .controlSize(.small)
                        .disabled(!DownloadRowText.canShowInFinder(item, missingFile: missingFiles.contains(item.id) || !checkedFiles.contains(item.id)))
                        .accessibilityLabel(DownloadRowText.showInFinderLabel(item))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

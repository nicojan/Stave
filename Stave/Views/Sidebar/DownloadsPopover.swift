import AppKit
import SwiftUI
import StaveCore

/// The bottom bar's downloads button: shown while the window's profile has downloads, opening the list as a popover.
struct DownloadsButton: View {
    let downloads: DownloadList
    let owner: DownloadOwner

    @State private var showing = false

    var body: some View {
        if !downloads.items(for: owner).isEmpty {
            Button { showing.toggle() } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.borderless)
                .help(DownloadRowText.buttonLabel)
                .accessibilityLabel(DownloadRowText.buttonLabel)
                .popover(isPresented: $showing, arrowEdge: .trailing) {
                    DownloadsPopover(downloads: downloads, owner: owner)
                }
        }
    }
}

/// This profile's downloads, newest first: each row's name, state and progress, with Cancel while it runs and Show in Finder once done;
/// Clear removes the rows that ended. Every label and enablement comes from `DownloadRowText`.
struct DownloadsPopover: View {
    let downloads: DownloadList
    let owner: DownloadOwner

    private var items: [DownloadItem] { downloads.items(for: owner) }

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
        .frame(minHeight: 80, maxHeight: 360)
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
                Text(DownloadRowText.status(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if DownloadRowText.canCancel(item) {
                    Button(DownloadRowText.cancelButton) { downloads.cancel(item.id) }
                        .controlSize(.small)
                        .accessibilityLabel(DownloadRowText.cancelLabel(item))
                }
                if let file = DownloadRowText.finishedFile(item) {
                    Button(DownloadRowText.showInFinderButton) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .controlSize(.small)
                        .accessibilityLabel(DownloadRowText.showInFinderLabel(item))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

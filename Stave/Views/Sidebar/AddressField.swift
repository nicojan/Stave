import AppKit
import SwiftUI
import StaveCore

/// What the address field needs to offer the per-site panel for the shown page: how to open it for a click or a key, the popover's state
/// (the window's presenter owns it), and the panel itself.
struct SitePanelAccess {
    var open: (ArchiveTrigger) -> Void
    var showing: Binding<Bool>
    var panel: () -> SitePanel
}

/// The selected tab's host. A button: it opens the command bar on the current tab. Beside it, when the page has a web site, a button for
/// the site's settings (camera, microphone, content blocking, zoom).
struct AddressField: View {
    let tab: StaveCore.Tab?
    let open: () -> Void
    var sitePanel: SitePanelAccess?

    var body: some View {
        HStack(spacing: 4) {
            field
            if let sitePanel { siteButton(sitePanel) }
        }
    }

    private var field: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(AddressFieldText.text(for: tab))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(AddressFieldText.isPlaceholder(for: tab) ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AddressFieldText.accessibilityLabel(for: tab))
        .accessibilityHint(AddressFieldText.hint)
    }

    private func siteButton(_ access: SitePanelAccess) -> some View {
        Button {
            // A mouse event behind the press means a click (popover); a key event or an accessibility press means the sheet.
            let pointer = NSApp.currentEvent.map { [.leftMouseDown, .leftMouseUp].contains($0.type) } ?? false
            access.open(ArchivePresentation.trigger(eventIsPointer: pointer))
        } label: {
            Image(systemName: "slider.horizontal.3")
                .padding(7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: access.showing, arrowEdge: .trailing) { access.panel() }
        .help(SitePanelText.buttonLabel)
        .accessibilityLabel(SitePanelText.buttonLabel)
    }
}

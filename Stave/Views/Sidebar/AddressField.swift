import SwiftUI
import StaveCore

/// The selected tab's host. A button: it opens the command bar on the current tab.
struct AddressField: View {
    let tab: StaveCore.Tab?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(AddressFieldText.text(for: tab))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(tab == nil || tab?.url.isEmpty == true ? .secondary : .primary)
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
}

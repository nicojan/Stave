import SwiftUI
import StaveCore

/// The profile's Essentials as monogram tiles, at least 52 x 44 pt, as many across as fit.
struct EssentialsGrid: View {
    let essentials: [StaveCore.Tab]
    let selectedID: UUID?
    let select: (UUID) -> Void
    let perform: (SidebarAction, UUID) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
            ForEach(essentials) { tab in
                tile(tab)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SidebarText.essentials)
    }

    private func tile(_ tab: StaveCore.Tab) -> some View {
        let title = DisplayText.title(for: tab)
        let isSelected = tab.id == selectedID
        return Button { select(tab.id) } label: {
            Text(DisplayText.monogram(for: tab))
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 10))
                .overlay { if isSelected { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5) } }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(SidebarLabels.essential(title: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sidebarActions(SidebarMenus.actions(forEssential: tab)) { perform($0, tab.id) }
    }
}

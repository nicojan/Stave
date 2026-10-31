import SwiftUI
import StaveCore

/// The command bar: a 600 pt overlay, centred in the window, over a transparent layer that closes it when clicked. The view draws
/// `CommandBarModel` and forwards keys; it never reads the typed text itself.
struct CommandBarView: View {
    @Bindable var bar: CommandBarModel
    let activate: () -> Void
    let close: () -> Void

    @FocusState private var fieldFocused: Bool

    static let width: CGFloat = 600

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                field
                Divider()
                if bar.isChoosingEngine { enginePicker } else { results }
            }
            .frame(width: Self.width)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { Task { fieldFocused = true } }
        .onExitCommand(perform: close)
    }

    private var field: some View {
        TextField(CommandBarText.placeholder, text: $bar.query)
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(14)
            .focused($fieldFocused)
            .accessibilityLabel(CommandBarText.fieldLabel)
            .onSubmit(activate)
            .onKeyPress(.upArrow) { bar.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { bar.moveSelection(by: 1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
    }

    private var results: some View {
        let rows = bar.rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows.indices, id: \.self) { index in
                        resultRow(rows[index], isSelected: index == bar.selectedIndex)
                            .id(index)
                            .onTapGesture { bar.select(index: index); activate() }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: rows.count < 7)
            .onChange(of: bar.selectedIndex) { _, new in proxy.scrollTo(new) }
        }
        .accessibilityLabel(CommandBarText.resultsLabel)
    }

    private func resultRow(_ row: CommandRow, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            icon(row.icon).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(row.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let secondary = row.secondary {
                Text(secondary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func icon(_ icon: CommandRowIcon) -> some View {
        if let name = icon.symbolName {
            Image(systemName: NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? WorkspaceIcon.fallbackSymbol : name)
        } else if case .workspace(.emoji(let emoji)) = icon {
            Text(emoji)
        }
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CommandBarText.enginePickerTitle).font(.headline).padding(.horizontal, 10).padding(.top, 8)
            Text(CommandBarText.enginePickerHint).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
            ForEach(Array(bar.engineChoices.enumerated()), id: \.offset) { index, engine in
                let isSelected = index == bar.engineIndex
                HStack {
                    Text(engine.displayName)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { bar.selectEngine(at: index); activate() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CommandBarText.engineRowLabel(engine))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CommandBarText.enginePickerLabel)
    }
}

import SwiftUI
import StaveCore

/// What the editor sheet is for.
enum WorkspaceEditorMode: Identifiable {
    case create
    case edit(Workspace)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let workspace): workspace.id.uuidString
        }
    }
}

/// Window-level UI requests the menus make of the sidebar: today, opening the workspace editor (Workspaces ▸ New Workspace…).
@MainActor @Observable
final class SidebarPresenter {
    var workspaceEditor: WorkspaceEditorMode?
}

/// A sheet to create or edit a workspace: name, an emoji or one of 12 symbols, and a colour from the palette. Validation is
/// `WorkspaceEditorRules`; Save is disabled until it passes. Pickers (not swatch buttons) keep every choice reachable by keyboard and labelled.
struct WorkspaceEditor: View {
    let mode: WorkspaceEditorMode
    let save: (WorkspaceDraft) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var emoji: String
    @State private var symbol: String
    @State private var colorHex: String
    @FocusState private var nameFocused: Bool

    private let original: Workspace?

    init(mode: WorkspaceEditorMode, save: @escaping (WorkspaceDraft) -> Void, cancel: @escaping () -> Void) {
        self.mode = mode; self.save = save; self.cancel = cancel
        switch mode {
        case .create:
            original = nil
            _name = State(initialValue: ""); _emoji = State(initialValue: ""); _symbol = State(initialValue: "")
            _colorHex = State(initialValue: WorkspaceEditorRules.defaultColorHex)
        case .edit(let workspace):
            original = workspace
            _name = State(initialValue: workspace.name)
            if case .emoji(let text) = WorkspaceIcon(stored: workspace.icon) {
                _emoji = State(initialValue: text); _symbol = State(initialValue: "")
            } else {
                _emoji = State(initialValue: ""); _symbol = State(initialValue: workspace.icon)
            }
            _colorHex = State(initialValue: workspace.colorHex)
        }
    }

    private var iconText: String { emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? symbol : emoji }

    private var draft: WorkspaceDraft? {
        WorkspaceEditorRules.validate(
            name: name, icon: iconText, colorHex: colorHex, allowingIcon: original?.icon, allowingColorHex: original?.colorHex
        )
    }

    private var emojiInvalid: Bool {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !WorkspaceEditorRules.isEmoji(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? WorkspaceEditorRules.newTitle : WorkspaceEditorRules.editTitle).font(.headline)
            Form {
                TextField(WorkspaceEditorRules.nameLabel, text: $name)
                    .focused($nameFocused)
                    .accessibilityLabel(WorkspaceEditorRules.nameLabel)
                TextField(WorkspaceEditorRules.emojiLabel, text: $emoji)
                    .accessibilityLabel(WorkspaceEditorRules.emojiLabel)
                if emojiInvalid {
                    Text(WorkspaceEditorRules.emojiHint).font(.caption).foregroundStyle(.red)
                }
                Picker(WorkspaceEditorRules.symbolLabel, selection: $symbol) {
                    Text(WorkspaceEditorRules.noSymbol).tag("")
                    ForEach(WorkspaceEditorRules.symbolChoices(including: original?.icon)) { choice in
                        Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
                    }
                }
                .accessibilityLabel(WorkspaceEditorRules.symbolLabel)
                .disabled(!emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Picker(WorkspaceEditorRules.colorLabel, selection: $colorHex) {
                    ForEach(WorkspaceEditorRules.colorChoices(including: original?.colorHex)) { choice in
                        Label { Text(choice.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(hex: choice.hex)) }
                            .tag(choice.hex)
                    }
                }
                .accessibilityLabel(WorkspaceEditorRules.colorLabel)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button(WorkspaceEditorRules.cancelButton, role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(WorkspaceEditorRules.saveButton) { if let draft { save(draft) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }
}

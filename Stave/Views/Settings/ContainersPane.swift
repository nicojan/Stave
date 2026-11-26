import SwiftUI
import StaveCore

/// What the container editor sheet is for.
private struct ContainerEditorState: Identifiable {
    var containerID: UUID?
    var profileID: UUID
    var name: String
    var colorHex: String
    /// The colour the container already has, which stays valid when unchanged.
    var originalColorHex: String?

    var id: String { containerID?.uuidString ?? "new-\(profileID)" }
}

/// Settings ▸ Containers: each profile's named containers with Create, Edit (name and colour) and Delete. Deleting asks first, and is refused
/// with the count while a tab still uses the container.
struct ContainersPane: View {
    let model: SettingsModel
    @State private var editor: ContainerEditorState?

    var body: some View {
        Form {
            ForEach(model.profiles) { profile in section(profile) }
            if let message = model.message(for: .containers) {
                Text(message).foregroundStyle(.red).accessibilityLabel(message)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editor) { state in
            ContainerEditor(state: state, save: save, cancel: { editor = nil })
        }
    }

    private func section(_ profile: Profile) -> some View {
        let containers = model.containers(profileID: profile.id)
        return Section(profile.name) {
            if containers.isEmpty { Text(SettingsCopy.noContainers).foregroundStyle(.secondary) }
            ForEach(containers) { container in row(container) }
            Button(SettingsCopy.createContainer) {
                editor = ContainerEditorState(
                    containerID: nil, profileID: profile.id, name: "", colorHex: WorkspaceEditorRules.defaultColorHex, originalColorHex: nil
                )
            }
            .accessibilityLabel(SettingsCopy.createContainerLabel(profileName: profile.name))
            .accessibilityInputLabels([SettingsCopy.createContainer])
        }
    }

    private func row(_ container: Container) -> some View {
        HStack {
            Circle().fill(Color(hex: container.colorHex)).frame(width: 12, height: 12).accessibilityHidden(true)
            Text(container.name)
            Spacer()
            Button(SettingsCopy.editContainer) {
                editor = ContainerEditorState(
                    containerID: container.id, profileID: container.profileID, name: container.name,
                    colorHex: container.colorHex, originalColorHex: container.colorHex
                )
            }
            .accessibilityLabel(SettingsCopy.editContainerLabel(name: container.name))
            .accessibilityInputLabels([SettingsCopy.editContainer])
            Button(SettingsCopy.deleteContainer) { delete(container) }
                .accessibilityLabel(SettingsCopy.deleteContainerLabel(name: container.name))
                .accessibilityInputLabels([SettingsCopy.deleteContainer])
        }
    }

    private func save(_ state: ContainerEditorState) {
        if let id = state.containerID {
            model.updateContainer(id, name: state.name, colorHex: state.colorHex)
        } else {
            model.createContainer(profileID: state.profileID, name: state.name, colorHex: state.colorHex)
        }
        editor = nil
    }

    private func delete(_ container: Container) {
        guard let plan = model.containerDeletion(container) else { return }
        switch plan {
        case .refused(let text): SettingsAlerts.inform(text)
        case .ask(let question):
            Task {
                guard await SettingsAlerts.confirmDestructive(question) else { return }
                await model.deleteContainer(container)
            }
        }
    }
}

/// The create / edit sheet: a name and a colour from the workspace palette. Pickers keep every choice reachable by keyboard and labelled.
private struct ContainerEditor: View {
    @State var state: ContainerEditorState
    let save: (ContainerEditorState) -> Void
    let cancel: () -> Void
    @FocusState private var nameFocused: Bool

    private var isValid: Bool {
        WorkspaceEditorRules.validate(
            name: state.name, icon: "", colorHex: state.colorHex, allowingColorHex: state.originalColorHex
        ) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.containerID == nil ? SettingsCopy.newContainerTitle : SettingsCopy.editContainerTitle).font(.headline)
            Form {
                TextField(SettingsCopy.containerNameField, text: $state.name)
                    .focused($nameFocused)
                    .accessibilityLabel(SettingsCopy.containerNameField)
                Picker(SettingsCopy.containerColourPicker, selection: $state.colorHex) {
                    ForEach(WorkspaceEditorRules.colorChoices(including: state.originalColorHex)) { choice in
                        Label { Text(choice.name) } icon: { Circle().fill(Color(hex: choice.hex)).frame(width: 10, height: 10) }.tag(choice.hex)
                    }
                }
                .accessibilityLabel(SettingsCopy.containerColourPicker)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button(SettingsCopy.cancelEdit, action: cancel).keyboardShortcut(.cancelAction)
                Button(SettingsCopy.saveContainer) { save(state) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }
}

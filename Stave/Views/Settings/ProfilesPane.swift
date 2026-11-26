import SwiftUI
import StaveCore

/// Settings ▸ Profiles: rename and delete. The question before a deletion and the order of its steps are `DeletionCopy` and `ProfileDeletion`.
struct ProfilesPane: View {
    let model: SettingsModel
    /// What the user has typed in each row's name field and not yet committed.
    @State private var drafts: [UUID: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(model.profiles) { profile in row(profile) }
            } footer: {
                Text(SettingsCopy.profilesFootnote).foregroundStyle(.secondary)
            }
            if let message = model.message(for: .profiles) {
                Text(message).foregroundStyle(.red).accessibilityLabel(message)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ profile: Profile) -> some View {
        HStack {
            TextField(SettingsCopy.profileNameField, text: Binding(get: { drafts[profile.id] ?? profile.name }, set: { drafts[profile.id] = $0 }))
                .labelsHidden() // the field's one label is its title; its value is the name
                .onSubmit { commit(profile) }
            Button(SettingsCopy.renameProfile) { commit(profile) }
                .disabled(drafts[profile.id] == nil || drafts[profile.id] == profile.name)
                .accessibilityLabel(SettingsCopy.renameProfileLabel(profileName: profile.name))
                .accessibilityInputLabels([SettingsCopy.renameProfile])
            Button(SettingsCopy.deleteProfile) { delete(profile) }
                .disabled(model.profiles.count <= 1)
                .accessibilityLabel(SettingsCopy.deleteProfileLabel(profileName: profile.name))
                .accessibilityInputLabels([SettingsCopy.deleteProfile])
        }
    }

    private func commit(_ profile: Profile) {
        guard let draft = drafts[profile.id] else { return }
        drafts[profile.id] = nil
        model.renameProfile(profile.id, to: draft)
    }

    private func delete(_ profile: Profile) {
        guard let question = model.profileDeletionQuestion(profile.id) else { return }
        Task {
            guard await SettingsAlerts.confirmDestructive(question) else { return }
            await model.deleteProfile(profile.id)
        }
    }
}

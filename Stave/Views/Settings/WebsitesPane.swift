import SwiftUI
import StaveCore

/// Settings ▸ Websites: every stored per-site answer and value of a profile, by host, with Remove and Remove All (which asks first).
struct WebsitesPane: View {
    let model: SettingsModel
    /// The front browser window's profile, read when the pane builds; the picker starts there (BH6).
    let frontProfileID: UUID?
    @State private var profileID: UUID?

    private var shownProfile: Profile? {
        let profiles = model.profiles
        let shown = WebsiteProfileChoice.shown(chosen: profileID, front: frontProfileID, in: profiles)
        return profiles.first { $0.id == shown }
    }

    var body: some View {
        Form {
            if model.profiles.count > 1 {
                Picker(SettingsCopy.websitesProfilePicker, selection: Binding(get: { shownProfile?.id }, set: { profileID = $0 })) {
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityLabel(SettingsCopy.websitesProfilePicker)
            }
            if let profile = shownProfile { entries(of: profile) }
            if let message = model.message(for: .websites) {
                Text(message).foregroundStyle(.red).accessibilityLabel(message)
            }
        }
        .formStyle(.grouped)
        // Pages write zoom and permission answers without going through the model, so the list is read again whenever the pane appears.
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private func entries(of profile: Profile) -> some View {
        let list = model.siteEntries(profileID: profile.id)
        Section {
            if list.isEmpty { Text(SettingsCopy.noWebsites).foregroundStyle(.secondary) }
            ForEach(list) { entry in
                HStack {
                    Text(entry.host)
                    Spacer()
                    Text(WebsiteEntryText.detail(entry)).foregroundStyle(.secondary)
                    Button(SettingsCopy.removeWebsite) { model.remove(entry) }
                        .accessibilityLabel(SettingsCopy.removeWebsiteLabel(entry))
                        .accessibilityInputLabels([SettingsCopy.removeWebsite])
                }
                .accessibilityElement(children: .contain)
            }
        }
        Button(SettingsCopy.removeAllWebsites) { removeAll(profile) }.disabled(list.isEmpty)
    }

    private func removeAll(_ profile: Profile) {
        Task {
            let question = DeletionCopy.removeAllWebsitesQuestion(profileName: profile.name)
            guard await SettingsAlerts.confirmDestructive(question, destructiveTitle: SettingsCopy.removeWebsite) else { return }
            model.removeAllSiteEntries(profileID: profile.id)
        }
    }
}

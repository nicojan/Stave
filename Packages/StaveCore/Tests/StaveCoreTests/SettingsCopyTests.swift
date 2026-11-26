import Foundation
import Testing
@testable import StaveCore

@MainActor
struct SettingsCopyTests {
    @Test func settingsCopyIsComplete() {
        let titles = SettingsPane.allCases.map(\.title)
        #expect(titles == ["General", "Tabs", "Profiles", "Containers", "Websites", "Advanced"])
        #expect(Set(titles).count == titles.count)
        #expect(SettingsPane.allCases.allSatisfy { !$0.symbol.isEmpty })
        // Every label of every pane (and of the alerts) is non-empty and unique within its own pane, so VoiceOver tells that pane's controls apart.
        let groups = SettingsPane.allCases.map { (name: $0.title, labels: SettingsCopy.labels(in: $0)) }
            + [(name: "alerts", labels: SettingsCopy.alertLabels)]
        for group in groups {
            #expect(!group.labels.isEmpty, "\(group.name) has labels")
            #expect(group.labels.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "\(group.name) labels are non-empty")
            #expect(Set(group.labels).count == group.labels.count, "\(group.name) labels are unique")
        }
    }

    /// The idle-tab picker's choices are labelled in the Tabs pane, and the read-only archive line reads differently from the "30 days" choice.
    @Test func tabsPaneListsThePickerChoicesAndKeepsThemApartFromTheTrimLine() {
        let labels = SettingsCopy.labels(in: .tabs)
        for choice in AutoArchiveAfter.allCases { #expect(labels.contains(choice.title), "\(choice.title)") }
        #expect(labels.contains(AutoArchiveAfter.settingTitle))
        #expect(SettingsCopy.archiveTrimValue != AutoArchiveAfter.days30.title)
    }

    @Test func everyKnownLabelIsInSomePane() {
        let all = SettingsPane.allCases.flatMap { SettingsCopy.labels(in: $0) } + SettingsCopy.alertLabels
        let expected = [
            DeletionCopy.deleteButton, DeletionCopy.cancelButton, SettingsCopy.okButton, SettingsCopy.noContainers, SettingsCopy.profilesFootnote,
            ExternalOpenText.defaultBrowserButton(isDefault: true).title, ExternalOpenText.defaultBrowserButton(isDefault: false).title,
            SettingsCopy.noWebsites, SettingsCopy.backupsFolderNote,
        ]
        for label in expected { #expect(all.contains(label), "\(label)") }
    }

    @Test func rowLabelsNameTheirRow() {
        #expect(SettingsCopy.renameProfileLabel(profileName: "Work") == "Rename the profile “Work”")
        #expect(SettingsCopy.deleteProfileLabel(profileName: "Work") == "Delete the profile “Work”")
        #expect(SettingsCopy.createContainerLabel(profileName: "Work") == "Create a container in the profile “Work”")
        #expect(SettingsCopy.editContainerLabel(name: "Bank") == "Edit the container “Bank”")
        #expect(SettingsCopy.deleteContainerLabel(name: "Bank") == "Delete the container “Bank”")
        // The two profiles' buttons read differently.
        #expect(SettingsCopy.renameProfileLabel(profileName: "A") != SettingsCopy.renameProfileLabel(profileName: "B"))
        let entry = SiteEntry(id: UUID(), profileID: UUID(), host: "example.com", kind: .setting(.camera), stored: "allow")
        #expect(SettingsCopy.removeWebsiteLabel(entry) == "Remove example.com: Camera, Allow")
        #expect(WebsiteEntryText.detail(entry) == "Camera: Allow")
    }

    /// A site write by a page (a zoom, a permission answer) shows in the model's next listing, and `refresh()` makes the pane re-read (BH2).
    @Test func siteWritesShowInTheNextListing() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.ensureDefaultProfile()
        let revision = StoreRevision()
        let deletion = ProfileDeletion(
            store: store, closePrivateSession: { _ in }, switchWindows: { _ in },
            removal: StoreRemoval(store: store) { _ in [:] }, session: nil, revision: revision
        )
        let model = SettingsModel(store: store, revision: revision, profileDeletion: deletion, removal: StoreRemoval(store: store) { _ in [:] })
        #expect(model.siteEntries(profileID: profile.id).isEmpty)
        try store.setSiteValue(profileID: profile.id, host: "a.example", key: .zoom, 1.25)
        #expect(model.siteEntries(profileID: profile.id).map(\.host) == ["a.example"])
        try store.setSiteDecision(profileID: profile.id, host: "b.example", key: .camera, .deny)
        #expect(model.siteEntries(profileID: profile.id).map(\.host) == ["a.example", "b.example"])
        let before = revision.value
        model.refresh()
        #expect(revision.value == before + 1)
    }

    @Test func backupStatusShowsFailureOnlyAfterThree() {
        let ok = SettingsCopy.backupStatus(consecutiveFailures: 0, failure: nil, hasSucceeded: true)
        #expect(ok.text == SettingsCopy.backupsWorking && !ok.isFailure)
        let fresh = SettingsCopy.backupStatus(consecutiveFailures: 0, failure: nil, hasSucceeded: false)
        #expect(fresh.text == SettingsCopy.backupsNoneYet)
        let two = SettingsCopy.backupStatus(consecutiveFailures: 2, failure: .checkFailed, hasSucceeded: true)
        #expect(!two.isFailure)
        let three = SettingsCopy.backupStatus(consecutiveFailures: 3, failure: .copyFailed("disk full"), hasSucceeded: false)
        #expect(three.isFailure)
        #expect(three.text == "Stave couldn't back up your data: the copy failed (disk full).")
    }

    @Test func websiteEntriesReadInWords() {
        func entry(_ kind: SiteEntry.Kind, _ stored: String) -> SiteEntry {
            SiteEntry(id: UUID(), profileID: UUID(), host: "example.com", kind: kind, stored: stored)
        }
        #expect(WebsiteEntryText.summary(entry(.setting(.camera), "allow")) == "example.com: Camera, Allow")
        #expect(WebsiteEntryText.summary(entry(.setting(.microphone), "deny")) == "example.com: Microphone, Block")
        #expect(WebsiteEntryText.summary(entry(.setting(.contentBlocking), "deny")) == "example.com: Content blocking, Off")
        #expect(WebsiteEntryText.summary(entry(.value(.zoom), "1.25")) == "example.com: Zoom, 125%")
        #expect(WebsiteEntryText.value(entry(.value(.userAgent), "\"Safari\"")) == "Safari")
    }

    @Test func websiteEntriesListAndRemove() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.ensureDefaultProfile()
        let other = try store.createProfile(name: "Other")
        try store.setSiteDecision(profileID: profile.id, host: "b.example", key: .camera, .allow)
        try store.setSiteValue(profileID: profile.id, host: "a.example", key: .zoom, 1.5)
        try store.setSiteDecision(profileID: other.id, host: "c.example", key: .camera, .deny)

        let entries = try store.siteEntries(profileID: profile.id)
        #expect(entries.map(\.host) == ["a.example", "b.example"])
        try store.removeSiteEntry(entries[0])
        #expect(try store.siteEntries(profileID: profile.id).map(\.host) == ["b.example"])
        #expect(try store.removeAllSiteEntries(profileID: profile.id) == 1)
        #expect(try store.siteEntries(profileID: profile.id).isEmpty)
        #expect(try store.siteEntries(profileID: other.id).count == 1) // another profile keeps its own
    }
}

/// `removeSite`, which the per-site panel's Reset This Site uses (plan 5, Task 13).
struct RemoveSiteTests {
    @Test func removeSiteTakesBothTablesForOneHostAndProfile() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        let other = try store.createProfile(name: "Q")
        try store.setSiteDecision(profileID: profile.id, host: "a.example", key: .camera, .allow)
        try store.setSiteDecision(profileID: profile.id, host: "a.example", key: .contentBlocking, .deny)
        try store.setSiteValue(profileID: profile.id, host: "a.example", key: .zoom, 1.5)
        try store.setSiteDecision(profileID: profile.id, host: "b.example", key: .camera, .deny)
        try store.setSiteDecision(profileID: other.id, host: "a.example", key: .camera, .allow)

        #expect(try store.removeSite(profileID: profile.id, host: "a.example") == 3)
        #expect(try store.siteEntries(profileID: profile.id).map(\.host) == ["b.example"])
        #expect(try store.siteEntries(profileID: other.id).count == 1)
        #expect(try store.removeSite(profileID: profile.id, host: "a.example") == 0)
    }
}

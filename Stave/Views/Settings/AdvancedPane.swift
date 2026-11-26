import SwiftUI
import StaveCore

/// Settings ▸ Advanced: the backups' status and "Show Backups in Finder". The passkey notice joins in Task 19.
struct AdvancedPane: View {
    let backups: DatabaseBackups?
    let showBackups: () -> Void

    var body: some View {
        Form {
            Section(SettingsCopy.backupsHeading) {
                if let backups {
                    let status = SettingsCopy.backupStatus(
                        consecutiveFailures: backups.consecutiveFailures, failure: backups.lastFailure, hasSucceeded: backups.lastSuccess != nil
                    )
                    Text(status.text)
                        .foregroundStyle(status.isFailure ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(status.text)
                }
                Text(SettingsCopy.backupsFolderNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(SettingsCopy.showBackups, action: showBackups)
                    .disabled(backups == nil)
                    .accessibilityLabel(SettingsCopy.showBackups)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

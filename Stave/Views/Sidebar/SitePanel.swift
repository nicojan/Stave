import SwiftUI
import StaveCore

/// The per-site panel (decision 20): one picker per row, and Reset This Site. Shown as a popover on the address field's site button for a
/// mouse click, and as a sheet for the keyboard and View ▸ Settings for This Website (as the archive is). Holds no rules: rows, labels and the effect of each choice come from `SitePanelModel`.
struct SitePanel: View {
    let make: () -> SitePanelModel?
    /// The site the page shows now (from the same address the button and the menu read). When it stops being the panel's site (a redirect
    /// or another page replaced it) the panel closes, so an edit never lands on a site the page has left.
    /// Read inside this view's own body, so the view tracks the page itself whether it sits in a popover or a sheet (R1-M4); the close applies to the popover too.
    let currentHost: () -> String?
    let done: () -> Void

    @State private var model: SitePanelModel?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model {
                content(model)
            } else if loaded {
                Text(SitePanelText.unavailable).foregroundStyle(.secondary)
                doneButton
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            guard !loaded else { return }
            model = make()
            loaded = true
        }
        .onChange(of: currentHost()) { _, host in
            if let model, model.isStale(shownHost: host) { done() }
        }
        .background(escapeToClose)
    }

    private func content(_ model: SitePanelModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.rows) { row in
                HStack {
                    // The picker below carries the row's spoken label ("Camera for example.com"), so this one is not read twice.
                    Text(row.label).accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Picker(row.label, selection: Binding(get: { row.selectedID }, set: { model.choose(row.kind, optionID: $0) })) {
                        ForEach(row.options) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .accessibilityLabel(SitePanelText.pickerLabel(row: row.label, host: model.host))
                }
            }
            // Only for apps that are installed, as in View ▸ Open in … (decision 25).
            ForEach(model.openElsewhere, id: \.self) { app in
                Button(app.menuTitle) { model.open(in: app) }
            }
            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(SitePanelText.resetButton) { model.resetSite() }
                    .disabled(!model.hasStoredValues)
                Spacer()
                doneButton
            }
        }
    }

    private var doneButton: some View {
        Button(SitePanelText.doneButton, action: done).keyboardShortcut(.defaultAction)
    }

    /// Escape closes the sheet: an invisible button that only carries the cancel shortcut (Done keeps Return). Not focusable, so Tab skips it.
    private var escapeToClose: some View {
        Button(SitePanelText.doneButton, action: done)
            .keyboardShortcut(.cancelAction)
            .focusable(false)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

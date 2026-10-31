import SwiftUI
import StaveCore

/// The first-run sheet: pick a search engine (none preselected), see the ⌃1–9 note, and optionally ask for the Arc import. Rules and copy
/// are in `FirstRun`; this only lays them out.
struct FirstRunView: View {
    let offersArcImport: Bool
    let shortcuts: WorkspaceShortcutsSetting?
    let onContinue: (SearchEngine, _ importFromArc: Bool) -> Void

    private static let rowHeight: CGFloat = 26

    @State private var engine: SearchEngine?
    @State private var importChosen = false

    var body: some View {
        let sections = FirstRun.sections(offersArcImport: offersArcImport)
        VStack(alignment: .leading, spacing: 18) {
            Text(FirstRun.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            if sections.searchEngine { engineSection }
            if sections.workspaceShortcutsNote, let shortcuts { shortcutsSection(shortcuts) }
            if sections.arcOffer { arcSection }
            HStack {
                Spacer()
                Button(FirstRun.continueTitle) {
                    guard let engine else { return }
                    onContinue(engine, FirstRun.opensImportAfterContinue(offersArcImport: offersArcImport, importChosen: importChosen))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!FirstRun.canContinue(engine: engine))
                .accessibilityLabel(FirstRun.continueTitle)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(FirstRun.enginePrompt).font(.headline)
            // A list, not radio buttons: a list takes the Tab key and the arrow keys without "Full Keyboard Access".
            List(SearchEngine.allCases, id: \.self, selection: $engine) { Text($0.displayName) }
                .frame(height: CGFloat(SearchEngine.allCases.count) * Self.rowHeight + 8)
                .scrollDisabled(true)
                .accessibilityLabel(FirstRun.enginePrompt)
        }
    }

    private func shortcutsSection(_ shortcuts: WorkspaceShortcutsSetting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(WorkspaceShortcutsSetting.title, isOn: Binding(get: { shortcuts.isEnabled }, set: { shortcuts.set($0) }))
                .accessibilityLabel(WorkspaceShortcutsSetting.title)
            Text(WorkspaceShortcutsSetting.note)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var arcSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FirstRun.arcOfferText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle(FirstRun.arcButtonTitle, isOn: $importChosen)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(FirstRun.arcButtonTitle)
                if importChosen {
                    Label(FirstRun.arcChosenText, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

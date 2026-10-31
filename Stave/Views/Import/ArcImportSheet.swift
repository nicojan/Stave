import SwiftUI
import StaveCore

/// The Arc import sheet. What it shows for each phase is `ArcImportSheetContent`; this renders it and sends each button to the flow.
/// While importing it has no buttons and cannot be dismissed.
struct ArcImportSheet: View {
    let session: ArcImportSession
    let chooseAnotherFile: () -> Void
    let close: () -> Void

    var body: some View {
        let flow = session.flow
        let content = ArcImportSheetContent(phase: flow.phase, source: session.source)
        VStack(alignment: .leading, spacing: 14) {
            Text(content.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let source = content.sourceDescription { Label(source, systemImage: "doc").foregroundStyle(.secondary) }
            if content.showsUnpinnedTabsToggle {
                @Bindable var flow = flow
                Toggle(ArcImportSheetContent.unpinnedTabsToggleTitle, isOn: $flow.includeUnpinnedTabs)
                    .accessibilityLabel(ArcImportSheetContent.unpinnedTabsToggleTitle)
            }
            ForEach(content.notices, id: \.self) { notice in
                Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = content.message { Text(message).fixedSize(horizontal: false, vertical: true) }
            if content.showsProgress {
                ProgressView().progressViewStyle(.circular).controlSize(.regular)
                    .accessibilityLabel(ArcImportSheetContent.importingTitle)
            }
            if !content.sections.isEmpty { sections(content.sections) }
            buttons(content, flow: flow)
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(!content.canDismiss)
    }

    private func sections(_ sections: [ArcImportSheetContent.Section]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
    }

    @ViewBuilder
    private func buttons(_ content: ArcImportSheetContent, flow: ArcImportFlow) -> some View {
        if content.primaryButton != nil || content.secondaryButton != nil {
            HStack {
                Spacer()
                if let secondary = content.secondaryButton {
                    Button(secondary.title) { run(secondary.action, flow: flow) }
                        .keyboardShortcut(secondary.action == .cancel ? Optional(KeyboardShortcut.cancelAction) : nil)
                        .accessibilityLabel(secondary.title)
                }
                if let primary = content.primaryButton {
                    Button(primary.title) { run(primary.action, flow: flow) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(primary.title)
                }
            }
        }
    }

    private func run(_ action: ArcImportSheetContent.Action, flow: ArcImportFlow) {
        switch action {
        case .cancel:
            flow.cancelRepeat()
            close()
        case .start: Task { await flow.start() }
        case .confirmRepeat: Task { await flow.confirmRepeat() }
        case .done, .close: close()
        case .chooseAnotherFile: chooseAnotherFile()
        }
    }
}

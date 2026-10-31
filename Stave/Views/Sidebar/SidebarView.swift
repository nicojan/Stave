import AppKit
import SwiftUI
import StaveCore

/// The sidebar of one window: pinned and regular rows over the sidebar material, tinted by the workspace colour. Plan 4 grows it in later tasks.
struct SidebarView: View {
    let model: BrowserWindowModel

    @FocusState private var listFocused: Bool
    @State private var dismissedError: String?
    /// The highlighted row. A tab row mirrors the model's selection; a folder row is only highlighted (it is not a tab, so the selection stays).
    @State private var highlighted: SidebarItemID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $highlighted) {
                ForEach(model.rows) { row in
                    SidebarRowView(row: row)
                        .tag(row.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .accessibilityLabel("Tabs")
            .onAppear {
                Task { listFocused = true } // after the window has made its first view key
                highlighted = model.selectedTabID.map { .tab($0) }
            }
            .onChange(of: highlighted) { _, new in
                if case .tab(let id)? = new { model.select(id) }
            }
            .onChange(of: model.selectedTabID) { _, new in
                if let new { highlighted = .tab(new) } else if case .tab? = highlighted { highlighted = nil }
            }
            errorBanner
        }
        .defaultFocus($listFocused, true)
        .padding(.top, 28) // clears the traffic lights, which sit over the sidebar
        .background { SidebarBackground(tintHex: model.snapshot.workspace.colorHex) }
        .ignoresSafeArea()
        .onChange(of: model.lastError) { _, new in if new == nil { dismissedError = nil } }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.lastError, message != dismissedError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { dismissedError = message } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss message")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct SidebarRowView: View {
    let row: SidebarRow

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(row.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let hex = row.containerColorHex {
                Circle().fill(Color(hex: hex)).frame(width: 7, height: 7).accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.kind {
        case .folder(let isOpen, _):
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary).frame(width: 16)
        case .pinnedTab:
            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).frame(width: 16)
        case .regularTab:
            Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

/// The sidebar material with the workspace colour at 12% over it.
private struct SidebarBackground: View {
    let tintHex: String

    var body: some View {
        ZStack {
            VisualEffect(material: .sidebar)
            Color(hex: tintHex).opacity(0.12)
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

extension Color {
    /// `#RRGGBB`; anything else is the system grey, so a bad stored value still draws.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255
        )
    }
}

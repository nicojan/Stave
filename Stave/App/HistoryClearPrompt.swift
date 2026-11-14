import AppKit
import StaveCore

/// History ▸ Clear History… and the History view's button: Safari's question, "Clear: ‹range›", as a sheet on the browser window
/// (decision 9). Clear removes the window's profile's visits in the range and, with "Also remove cookies and website data" ticked (the
/// default; question 16, answered 2026-11-14), the website data of every persistent store of that profile modified in the range.
extension BrowserWindowController {
    func promptClearHistory() {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = HistoryText.clearPromptTitle
        alert.informativeText = HistoryText.clearPromptMessage
        let ranges = HistoryClearRange.allCases
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ranges.map(\.title))
        popup.selectItem(at: ranges.firstIndex(of: .lastHour) ?? 0)
        popup.setAccessibilityLabel(HistoryText.clearRangeLabel)
        let label = NSTextField(labelWithString: HistoryText.clearRangeLabel)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        let websiteData = NSButton(checkboxWithTitle: HistoryText.clearWebsiteDataCheckbox, target: nil, action: nil)
        websiteData.state = HistoryText.clearWebsiteDataByDefault ? .on : .off
        let accessory = NSStackView(views: [row, websiteData])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
        alert.accessoryView = accessory
        alert.addButton(withTitle: HistoryText.clearConfirm)
        alert.addButton(withTitle: HistoryText.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, ranges.indices.contains(popup.indexOfSelectedItem) else { return }
            let range = ranges[popup.indexOfSelectedItem]
            let alsoWebsiteData = websiteData.state == .on
            Task { @MainActor [weak self] in await self?.model.clearHistory(range, alsoWebsiteData: alsoWebsiteData) }
        }
    }
}

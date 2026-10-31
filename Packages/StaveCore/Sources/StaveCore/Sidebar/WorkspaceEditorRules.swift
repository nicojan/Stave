import Foundation

public struct PaletteColor: Equatable, Sendable, Identifiable {
    public var name: String
    public var hex: String
    public var id: String { hex }
    public init(name: String, hex: String) { self.name = name; self.hex = hex }
}

public struct PaletteSymbol: Equatable, Sendable, Identifiable {
    public var name: String
    public var symbol: String
    public var id: String { symbol }
    public init(name: String, symbol: String) { self.name = name; self.symbol = symbol }
}

/// A validated editor result, ready for `createWorkspace` / `updateWorkspace`.
public struct WorkspaceDraft: Equatable, Sendable {
    public var name: String
    public var icon: String
    public var colorHex: String
    public init(name: String, icon: String, colorHex: String) { self.name = name; self.icon = icon; self.colorHex = colorHex }
}

/// The workspace editor's palette and validation. The store accepts anything, so this is where the rules live.
public enum WorkspaceEditorRules {
    public static let homeGrey = "#8E8E93"

    /// Eight colours plus Home grey.
    public static let colors: [PaletteColor] = [
        PaletteColor(name: "Red", hex: "#FF3B30"), PaletteColor(name: "Orange", hex: "#FF9500"),
        PaletteColor(name: "Yellow", hex: "#FFCC00"), PaletteColor(name: "Green", hex: "#34C759"),
        PaletteColor(name: "Teal", hex: "#30B0C7"), PaletteColor(name: "Blue", hex: "#3478F6"),
        PaletteColor(name: "Purple", hex: "#AF52DE"), PaletteColor(name: "Pink", hex: "#FF2D55"),
        PaletteColor(name: "Grey", hex: homeGrey)
    ]

    public static let symbols: [PaletteSymbol] = [
        PaletteSymbol(name: "Home", symbol: "house"), PaletteSymbol(name: "Work", symbol: "briefcase"),
        PaletteSymbol(name: "Study", symbol: "book"), PaletteSymbol(name: "Shopping", symbol: "cart"),
        PaletteSymbol(name: "Ideas", symbol: "lightbulb"), PaletteSymbol(name: "Music", symbol: "music.note"),
        PaletteSymbol(name: "Games", symbol: "gamecontroller"), PaletteSymbol(name: "Travel", symbol: "airplane"),
        PaletteSymbol(name: "Code", symbol: "chevron.left.forwardslash.chevron.right"), PaletteSymbol(name: "Design", symbol: "paintbrush"),
        PaletteSymbol(name: "Favourite", symbol: "star"), PaletteSymbol(name: "Heart", symbol: "heart")
    ]

    public static let defaultColorHex = "#3478F6"
    public static let defaultSymbol = "square.grid.2x2"

    /// The palette, plus the colour an existing workspace already has when it is not in it (an imported one), so editing never forces a change.
    public static func colorChoices(including current: String?) -> [PaletteColor] {
        guard let current, !current.isEmpty, paletteColor(current) == nil else { return colors }
        return colors + [PaletteColor(name: "Current", hex: current)]
    }

    /// The symbols, plus the one an existing workspace already has when it is not in the list.
    public static func symbolChoices(including current: String?) -> [PaletteSymbol] {
        guard let current, !current.isEmpty, !current.unicodeScalars.contains(where: { !$0.isASCII }),
              !symbols.contains(where: { $0.symbol == current }) else { return symbols }
        return symbols + [PaletteSymbol(name: "Current", symbol: current)]
    }

    /// Name trimmed and non-empty; icon empty, an emoji, or a symbol from the list; colour from the palette. Nil means "Save is disabled".
    /// `allowing` names the icon and colour the workspace being edited already has, which stay valid when unchanged.
    public static func validate(
        name: String, icon: String, colorHex: String, allowingIcon: String? = nil, allowingColorHex: String? = nil
    ) -> WorkspaceDraft? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let trimmedIcon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIcon(trimmedIcon) || (!trimmedIcon.isEmpty && trimmedIcon == allowingIcon) else { return nil }
        guard let color = paletteColor(colorHex)?.hex ?? allowedColor(colorHex, allowing: allowingColorHex) else { return nil }
        return WorkspaceDraft(name: trimmedName, icon: trimmedIcon, colorHex: color)
    }

    /// Empty, a single emoji, or one of the listed symbols.
    public static func isValidIcon(_ icon: String) -> Bool {
        icon.isEmpty || isEmoji(icon) || symbols.contains { $0.symbol == icon }
    }

    /// One character, not ASCII, with an emoji scalar. (`WorkspaceIcon` treats any non-ASCII icon as an emoji.)
    public static func isEmoji(_ text: String) -> Bool {
        guard text.count == 1, let first = text.unicodeScalars.first, !first.isASCII else { return false }
        return text.unicodeScalars.contains { $0.properties.isEmoji }
    }

    private static func paletteColor(_ hex: String) -> PaletteColor? {
        colors.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    private static func allowedColor(_ hex: String, allowing: String?) -> String? {
        guard let allowing, hex.caseInsensitiveCompare(allowing) == .orderedSame, HexColor.rgb(allowing) != nil else { return nil }
        return allowing
    }

    // MARK: - Editor text

    public static let newTitle = "New Workspace"
    public static let editTitle = "Edit Workspace"
    public static let nameLabel = "Name"
    public static let emojiLabel = "Emoji"
    public static let emojiHint = "Use a single emoji, or leave this empty to use a symbol."
    public static let noSymbol = "None"
    public static let symbolLabel = "Symbol"
    public static let colorLabel = "Colour"
    public static let saveButton = "Save"
    public static let cancelButton = "Cancel"
}

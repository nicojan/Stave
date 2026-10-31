import Foundation

public struct RGBColor: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
}

public enum HexColor {
    /// `#RRGGBB` or `RRGGBB` (ASCII hex digits only) as 0...1 components; anything else is nil, and the view picks its fallback.
    public static func rgb(_ hex: String) -> RGBColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.utf8.count == 6, digits.unicodeScalars.allSatisfy({ $0.isASCII && Character($0).isHexDigit }),
              let value = UInt32(digits, radix: 16) else { return nil }
        return RGBColor(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255
        )
    }
}

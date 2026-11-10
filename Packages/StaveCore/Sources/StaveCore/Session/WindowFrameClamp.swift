import CoreGraphics

/// Puts a restored window frame back onto a screen. Pure rectangle math: the app passes each screen's visible frame.
public enum WindowFrameClamp {
    /// The frame moved fully onto the screen it overlaps most, shrunk to fit if larger. A frame overlapping no screen is centred on the
    /// first one (same size, shrunk to fit). With no screens the frame is returned unchanged.
    public static func clamp(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect {
        guard let first = visibleFrames.first else { return frame }
        let best = visibleFrames.map { (screen: $0, area: overlapArea(frame, $0)) }
            .reduce((screen: first, area: overlapArea(frame, first))) { $1.area > $0.area ? $1 : $0 }
        let screen = best.screen
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        guard best.area > 0 else {
            return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        }
        let x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}

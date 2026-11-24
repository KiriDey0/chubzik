import CoreGraphics
import Foundation

enum QuickChatRegion {
    static let minimumTravel: CGFloat = 16

    static func selection(from start: CGPoint, to end: CGPoint, on screen: CGRect) -> CGRect? {
        let end = CGPoint(x: min(screen.maxX, max(screen.minX, end.x)),
                          y: min(screen.maxY, max(screen.minY, end.y)))
        let width = abs(end.x - start.x), height = abs(end.y - start.y)
        guard hypot(width, height) >= minimumTravel, width >= 4, height >= 4 else { return nil }

        func align(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            if value - lower <= 4 { return lower }
            if upper - value <= 4 { return upper }
            return value
        }

        let left = align(min(start.x, end.x), lower: screen.minX, upper: screen.maxX)
        let right = align(max(start.x, end.x), lower: screen.minX, upper: screen.maxX)
        let bottom = align(min(start.y, end.y), lower: screen.minY, upper: screen.maxY)
        let top = align(max(start.y, end.y), lower: screen.minY, upper: screen.maxY)
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom).integral.intersection(screen)
    }

    /// Converts global AppKit points to ScreenCaptureKit's top-left display coordinates.
    static func captureRect(_ area: CGRect, on screen: CGRect) -> CGRect {
        CGRect(x: area.minX - screen.minX, y: screen.maxY - area.maxY,
               width: area.width, height: area.height)
    }
}

enum QuickChatAnchor {
    static func follows(_ point: CGPoint, from anchor: CGPoint, panel: CGRect) -> Bool {
        let panelSide = panel.midX >= anchor.x ? panel.minX : panel.maxX
        let bridge = CGRect(x: min(anchor.x, panelSide) - 2, y: anchor.y - 28,
                            width: abs(anchor.x - panelSide) + 4, height: 56)
        return !panel.insetBy(dx: -10, dy: -10).contains(point) && !bridge.contains(point)
            && hypot(point.x - anchor.x, point.y - anchor.y) >= 3
    }
}

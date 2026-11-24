import AppKit
import QuartzCore

final class NotchPanelMotion {
    private let mask = CAShapeLayer()
    private weak var hostLayer: CALayer?
    private var removeMask: DispatchWorkItem?

    func open(_ view: NSView, notchWidth: CGFloat, scale: CGFloat, from previousSize: CGSize? = nil) {
        run(view, notchWidth: notchWidth, scale: scale, previousSize: previousSize, closing: false)
    }

    static let closingDuration = 0.17

    func close(_ view: NSView, notchWidth: CGFloat, scale: CGFloat) {
        run(view, notchWidth: notchWidth, scale: scale, previousSize: nil, closing: true)
    }

    func reset() {
        removeMask?.cancel()
        removeMask = nil
        mask.removeAllAnimations()
        if hostLayer?.mask === mask { hostLayer?.mask = nil }
        hostLayer = nil
    }

    private func run(_ view: NSView, notchWidth: CGFloat, scale: CGFloat, previousSize: CGSize?, closing: Bool) {
        guard let layer = view.layer else { return }
        removeMask?.cancel()
        let bounds = layer.bounds
        let compact = previousSize ?? CGSize(width: notchWidth + 8, height: NotchGeometry.panelNotchOverlap)
        let startRect = CGRect(x: bounds.midX - compact.width / 2, y: 0,
                               width: compact.width, height: compact.height)

        func silhouette(_ rect: CGRect) -> CGPath {
            let path = NotchSurface.path(in: rect, notchWidth: notchWidth, scale: scale)
            guard !layer.isGeometryFlipped else { return path }
            var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
            return path.copy(using: &flip) ?? path
        }

        let full = silhouette(CGRect(origin: .zero, size: bounds.size))
        let narrow = silhouette(startRect)
        let current = layer.mask === mask ? mask.presentation()?.path ?? mask.path : nil
        let destination = closing ? narrow : full

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer = layer
        mask.frame = bounds
        mask.path = destination
        mask.fillColor = NSColor.white.cgColor
        layer.mask = mask
        let transition = CABasicAnimation(keyPath: "path")
        transition.fromValue = current ?? (closing ? full : narrow)
        transition.toValue = destination
        transition.duration = closing ? Self.closingDuration : 0.22
        transition.timingFunction = closing
            ? CAMediaTimingFunction(controlPoints: 0.42, 0, 0.78, 0.88)
            : CAMediaTimingFunction(controlPoints: 0.18, 0.75, 0.26, 1)
        mask.add(transition, forKey: "notch-contour")
        CATransaction.commit()

        if !closing {
            let cleanup = DispatchWorkItem { [weak self] in self?.reset() }
            removeMask = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + transition.duration, execute: cleanup)
        }
    }
}

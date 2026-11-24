import AppKit
import QuartzCore

@main enum MotionTests {
    static func main() throws {
        _ = NSApplication.shared
        let mascot = freshMascot()
        let layers = mascot.layer!.sublayers!
        let body = layers.first { $0.name == "creature" }!
        let face = body.sublayers!.first { $0.name == "face" }!
        let cheeks = body.sublayers!.first { $0.name == "cheeks" }!
        let badge = layers.first { $0.name == "reaction-badge" }!
        let indicator = layers.first { $0.name == "attention" }!
        let outline = body.sublayers!.compactMap { $0 as? CAShapeLayer }.first!
        let mask = body.sublayers!.first { $0 is CAGradientLayer }!.mask as! CAShapeLayer
        let idle = outline.path!
        mascot.extendPaw(.init(side: 1, amount: 1))
        precondition(outline.path == mask.path && outline.path!.boundingBoxOfPath.maxX > idle.boundingBoxOfPath.maxX + 1)
        precondition(outline.path!.boundingBoxOfPath.maxY > idle.boundingBoxOfPath.maxY + 1)
        mascot.extendPaw(.init(side: -1, amount: 1))
        precondition(outline.path == mask.path && outline.path!.boundingBoxOfPath.minX < idle.boundingBoxOfPath.minX - 1)
        mascot.extendPaw(nil)
        precondition(outline.path == idle && mask.path == idle)

        mascot.look(CGPoint(x: 2, y: -1))
        let firstLook = face.animation(forKey: "gaze") as! CABasicAnimation
        precondition((firstLook.fromValue as? NSValue)?.caTransform3DValue.m41 == 0)
        precondition((firstLook.toValue as? NSValue)?.caTransform3DValue.m41 == 2 && firstLook.duration == 0.11)
        mascot.look(CGPoint(x: -2.2, y: 1))
        let redirected = face.animation(forKey: "gaze") as! CABasicAnimation
        precondition((redirected.toValue as? NSValue)?.caTransform3DValue.m41 == -2.2)
        precondition(face.affineTransform().tx == -2.2 && face.animationKeys() == ["gaze"])
        mascot.react(.curious(1))
        precondition(face.animation(forKey: "gaze") == nil)
        precondition(face.animation(forKey: "curiosity")?.duration == 1.26)
        mascot.look(CGPoint(x: -2.2, y: 1))
        precondition(face.animation(forKey: "curiosity") == nil)
        mascot.setChatExpression(.capture)
        precondition(face.animationKeys() == ["gaze"] && face.affineTransform().tx == -2.8)
        mascot.react(.curious(1))
        mascot.hold(true)
        precondition(cheeks.opacity == 1 && body.affineTransform().d < 1)
        precondition(face.animation(forKey: "curiosity") == nil && body.animation(forKey: "reaction") == nil)
        mascot.hold(false)
        precondition(body.affineTransform() == .identity && body.animation(forKey: "touch")?.duration == 0.27)
        mascot.clearBlush()
        precondition(cheeks.opacity == 0)

        mascot.react(.file)
        let file = (badge as! CAShapeLayer).path!
        precondition(badge.animation(forKey: "badge")?.duration == 0.97)
        mascot.react(.timer)
        precondition(file != (badge as! CAShapeLayer).path!)
        mascot.mood = .awaiting
        mascot.react(.attention)
        precondition(!indicator.isHidden && indicator.animation(forKey: "signal")?.duration == 0.52)

        let tree = allLayers(mascot.layer!)
        let animations = tree.flatMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        }
        precondition(!animations.isEmpty)
        precondition(animations.allSatisfy { $0.repeatCount == 0 && $0.isRemovedOnCompletion })
        mascot.reducedMotion = true
        precondition(tree.allSatisfy { $0.animationKeys()?.isEmpty != false })
        mascot.look(CGPoint(x: 2, y: 0))
        precondition(face.affineTransform() == .identity)
        mascot.react(.timer)
        mascot.react(.attention)
        mascot.react(.file)
        precondition(badge.opacity == 1)
        mascot.hold(true)
        precondition(cheeks.opacity == 1 && body.affineTransform() == .identity && !indicator.isHidden)
        mascot.hold(false)
        mascot.clearBlush()
        precondition(tree.allSatisfy { $0.animationKeys()?.isEmpty != false })
        print("Mascot poses, distinct feedback, finite animations, and reduced motion passed")

        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render("idle", in: directory) { _ in }
            try render("paw", in: directory) { $0.extendPaw(.init(side: -1, amount: 1)) }
            try render("glance", in: directory) { $0.react(.curious(1)) }
            try render("press", in: directory) { $0.hold(true) }
            try render("release", in: directory) { $0.hold(true); $0.hold(false) }
            try render("file", in: directory) { $0.react(.file) }
            try render("timer", in: directory) { $0.react(.timer) }
            try render("attention", in: directory) { $0.mood = .awaiting; $0.react(.attention) }
            try render("return", in: directory) { $0.travel(toward: CGPoint(x: 190, y: 110), duration: 0.41) }
        }
    }

    private static func freshMascot() -> MascotView {
        MascotView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    }

    private static func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(allLayers)
    }

    private static func render(_ name: String, in directory: URL, configure: (MascotView) -> Void) throws {
        let mascot = freshMascot()
        configure(mascot)
        let root = mascot.layer!
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in allLayers(root) {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) as? CAKeyframeAnimation,
                      let times = animation.keyTimes, let values = animation.values else { continue }
                let time = name == "release" ? 0.33 : 0.43
                let index = times.indices.min { abs(times[$0].doubleValue - time) < abs(times[$1].doubleValue - time) }!
                if animation.keyPath == "opacity", let opacity = values[index] as? NSNumber {
                    layer.opacity = opacity.floatValue
                } else if animation.keyPath == "path", let shape = layer as? CAShapeLayer {
                    shape.path = (values[index] as! CGPath)
                } else if let transform = values[index] as? NSValue {
                    layer.transform = transform.caTransform3DValue
                }
                layer.removeAnimation(forKey: key)
            }
        }
        CATransaction.commit()

        let context = CGContext(data: nil, width: 144, height: 144, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 4, y: 4)
        context.translateBy(x: 2, y: 2)
        root.render(in: context)
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

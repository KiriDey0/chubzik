import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: Double(pixels) / 1024, y: Double(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 93, y: 93, width: 838, height: 838), xRadius: 189, yRadius: 189)
        NSGradient(starting: NSColor(srgbRed: 0.31, green: 0.25, blue: 0.35, alpha: 1),
                   ending: NSColor(srgbRed: 0.11, green: 0.10, blue: 0.17, alpha: 1))?.draw(in: tile, angle: -60)
        let pebble = NSBezierPath(roundedRect: NSRect(x: 229, y: 252, width: 565, height: 510), xRadius: 251, yRadius: 246)
        NSGradient(starting: NSColor(srgbRed: 0.31, green: 0.28, blue: 0.34, alpha: 1),
                   ending: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.165, alpha: 1))?.draw(in: pebble, angle: -73)
        NSColor(white: 0.79, alpha: 0.54).setStroke()
        pebble.lineWidth = 11
        pebble.stroke()
        NSColor(srgbRed: 1, green: 0.95, blue: 0.86, alpha: 1).setFill()
        for x in [407, 554] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 437, width: 63, height: 171), xRadius: 33, yRadius: 33).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

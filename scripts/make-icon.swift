import AppKit
import Foundation

let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let tile = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(red: 0.16, green: 0.30, blue: 0.63, alpha: 1), ending: NSColor(red: 0.25, green: 0.54, blue: 0.97, alpha: 1))!.draw(in: tile, angle: 60)
    let monitor = NSBezierPath(roundedRect: NSRect(x: 182, y: 330, width: 660, height: 434), xRadius: 38, yRadius: 38)
    NSColor.white.withAlphaComponent(0.94).setStroke(); monitor.lineWidth = 28; monitor.stroke()
    NSColor.white.withAlphaComponent(0.18).setFill(); monitor.fill()
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(roundedRect: NSRect(x: 470, y: 220, width: 84, height: 110), xRadius: 8, yRadius: 8).fill()
    NSBezierPath(roundedRect: NSRect(x: 372, y: 196, width: 280, height: 30), xRadius: 15, yRadius: 15).fill()
    return true
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

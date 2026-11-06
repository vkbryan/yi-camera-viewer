// Draws the 1024px app icon: a camera glyph on a dark rounded square.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let tile = rect.insetBy(dx: 100, dy: 100)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1))!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 380, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.35, green: 0.85, blue: 0.75, alpha: 1)]))
    if let glyph = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = glyph.size
        glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

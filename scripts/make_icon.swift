import AppKit

// Original code-drawn artwork; generated only by the macOS build runner.
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: NSColor(red: 0.09, green: 0.24, blue: 0.29, alpha: 1),
           ending: NSColor(red: 0.02, green: 0.08, blue: 0.14, alpha: 1))!.draw(in: rect, angle: 45)
let line = NSBezierPath()
line.move(to: NSPoint(x: 290, y: 260)); line.line(to: NSPoint(x: 290, y: 735))
line.line(to: NSPoint(x: 630, y: 735)); line.curve(to: NSPoint(x: 630, y: 445), controlPoint1: NSPoint(x: 835, y: 735), controlPoint2: NSPoint(x: 835, y: 445))
line.line(to: NSPoint(x: 290, y: 445)); line.lineWidth = 64; line.lineCapStyle = .round; line.lineJoinStyle = .round
NSColor(red: 0.44, green: 0.96, blue: 0.80, alpha: 1).setStroke(); line.stroke()
for point in [NSPoint(x: 290, y: 260), NSPoint(x: 290, y: 735), NSPoint(x: 630, y: 445)] {
    let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 68, y: point.y - 68, width: 136, height: 136))
    NSColor(red: 0.82, green: 1, blue: 0.95, alpha: 1).setFill(); circle.fill()
}
NSGraphicsContext.restoreGraphicsState()
let directory = URL(fileURLWithPath: "ios/Pocket/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("AppIcon.png"))

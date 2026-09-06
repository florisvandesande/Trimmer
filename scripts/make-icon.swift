import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205).fill()
        NSColor(calibratedRed: 1, green: 0.79, blue: 0.16, alpha: 1).setStroke()
        let brackets = NSBezierPath()
        brackets.lineWidth = 42; brackets.lineCapStyle = .round; brackets.lineJoinStyle = .round
        brackets.move(to: NSPoint(x: 294, y: 710)); brackets.line(to: NSPoint(x: 232, y: 710))
        brackets.line(to: NSPoint(x: 232, y: 314)); brackets.line(to: NSPoint(x: 294, y: 314))
        brackets.move(to: NSPoint(x: 730, y: 710)); brackets.line(to: NSPoint(x: 792, y: 710))
        brackets.line(to: NSPoint(x: 792, y: 314)); brackets.line(to: NSPoint(x: 730, y: 314)); brackets.stroke()
        NSColor(calibratedRed: 0.91, green: 0.89, blue: 0.81, alpha: 1).setFill()
        for (index, height) in [110.0, 205, 340, 250, 420, 190, 115].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 336 + Double(index) * 52, y: 512 - height / 2, width: 26, height: height), xRadius: 13, yRadius: 13).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: root.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}

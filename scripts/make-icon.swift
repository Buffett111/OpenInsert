import AppKit
import Foundation

let directory = URL(fileURLWithPath: ".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        let path = NSBezierPath(roundedRect: rect, xRadius: p * 0.22, yRadius: p * 0.22)
        NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.64, blue: 0.46, alpha: 1),
                   ending: NSColor(calibratedRed: 0.05, green: 0.28, blue: 0.27, alpha: 1))!.draw(in: path, angle: -60)
        NSColor.white.setFill()
        for (index, height) in [0.18, 0.36, 0.55, 0.30, 0.16].enumerated() {
            let bar = NSRect(x: p * (0.23 + Double(index) * 0.115), y: p * (0.50 - height / 2), width: p * 0.065, height: p * height)
            NSBezierPath(roundedRect: bar, xRadius: p * 0.033, yRadius: p * 0.033).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

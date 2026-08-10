import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first
    ?? "bridge/assets/AppIcon-1024.png"
let canvasSize = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not create the app icon canvas.")
}
bitmap.size = canvasSize
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create the app icon drawing context.")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill(using: .copy)

let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 218, yRadius: 218)
NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
tile.fill()

let innerBorder = NSBezierPath(
    roundedRect: tileRect.insetBy(dx: 2.5, dy: 2.5),
    xRadius: 215.5,
    yRadius: 215.5
)
innerBorder.lineWidth = 5
NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
innerBorder.stroke()

let palette = NSImage.SymbolConfiguration(paletteColors: [.white])
let sizing = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
if let base = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil),
   let symbol = base.withSymbolConfiguration(sizing.applying(palette)) {
    let maximum = NSSize(width: 640, height: 420)
    let scale = min(maximum.width / symbol.size.width, maximum.height / symbol.size.height)
    let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let rect = NSRect(
        x: (canvasSize.width - size.width) / 2,
        y: (canvasSize.height - size.height) / 2 - 4,
        width: size.width,
        height: size.height
    )
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
} else {
    fatalError("The required SF Symbol is unavailable on this version of macOS.")
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the app icon.")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
print(outputURL.path)

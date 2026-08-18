import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func scaled(_ value: CGFloat, for size: Int) -> CGFloat {
    value * CGFloat(size) / 1024
}

for (name, size) in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let tile = canvas.insetBy(dx: scaled(72, for: size), dy: scaled(72, for: size))
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: scaled(220, for: size), yRadius: scaled(220, for: size))
    NSColor(calibratedRed: 0.105, green: 0.118, blue: 0.125, alpha: 1).setFill()
    tilePath.fill()

    let center = NSPoint(x: scaled(512, for: size), y: scaled(500, for: size))
    let ringColor = NSColor(calibratedRed: 0.84, green: 0.87, blue: 0.86, alpha: 1)
    ringColor.setStroke()
    for radius in [252.0, 174.0, 96.0] {
        let r = scaled(radius, for: size)
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        path.lineWidth = max(1, scaled(28, for: size))
        path.stroke()
    }

    let signalRadius = scaled(58, for: size)
    let signal = NSBezierPath(ovalIn: NSRect(
        x: center.x - signalRadius,
        y: center.y - signalRadius,
        width: signalRadius * 2,
        height: signalRadius * 2
    ))
    NSColor(calibratedRed: 0.43, green: 0.89, blue: 0.39, alpha: 1).setFill()
    signal.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: output.appendingPathComponent(name))
}

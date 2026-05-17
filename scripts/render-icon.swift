import AppKit
import CoreGraphics
import Foundation

struct IconSpec {
    let name: String
    let pixels: Int
}

let specs = [
    IconSpec(name: "icon_16x16.png", pixels: 16),
    IconSpec(name: "icon_16x16@2x.png", pixels: 32),
    IconSpec(name: "icon_32x32.png", pixels: 32),
    IconSpec(name: "icon_32x32@2x.png", pixels: 64),
    IconSpec(name: "icon_128x128.png", pixels: 128),
    IconSpec(name: "icon_128x128@2x.png", pixels: 256),
    IconSpec(name: "icon_256x256.png", pixels: 256),
    IconSpec(name: "icon_256x256@2x.png", pixels: 512),
    IconSpec(name: "icon_512x512.png", pixels: 512),
    IconSpec(name: "icon_512x512@2x.png", pixels: 1024),
]

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift render-icon.swift <output.iconset>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for spec in specs {
    let image = renderIcon(size: spec.pixels)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to encode \(spec.name)\n", stderr)
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent(spec.name), options: .atomic)
}

func renderIcon(size: Int) -> CGImage {
    let scale = CGFloat(size) / 1024.0
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("failed to create CGContext")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.scaleBy(x: scale, y: scale)

    let iconRect = CGRect(x: 72, y: 72, width: 880, height: 880)
    let iconPath = CGPath(roundedRect: iconRect, cornerWidth: 214, cornerHeight: 214, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -28), blur: 42, color: rgba(0x00143f, 0.32))
    context.addPath(iconPath)
    context.setFillColor(rgba(0x246bff, 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(iconPath)
    context.clip()
    let bgGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgba(0x38c7ff, 1), rgba(0x246bff, 1), rgba(0x0b2f83, 1)] as CFArray,
        locations: [0, 0.54, 1]
    )!
    context.drawLinearGradient(bgGradient, start: CGPoint(x: 130, y: 942), end: CGPoint(x: 894, y: 82), options: [])

    context.addPath(CGPath(roundedRect: CGRect(x: 116, y: 802, width: 792, height: 106), cornerWidth: 72, cornerHeight: 72, transform: nil))
    context.setFillColor(rgba(0xffffff, 0.20))
    context.fillPath()

    let windowPath = CGPath(roundedRect: CGRect(x: 234, y: 358, width: 556, height: 420), cornerWidth: 76, cornerHeight: 76, transform: nil)
    context.addPath(windowPath)
    context.setFillColor(rgba(0xffffff, 0.18))
    context.fillPath()
    context.addPath(windowPath)
    context.setStrokeColor(rgba(0xffffff, 0.22))
    context.setLineWidth(18)
    context.strokePath()

    context.restoreGState()

    context.addPath(CGPath(roundedRect: CGRect(x: 214, y: 162, width: 596, height: 132), cornerWidth: 50, cornerHeight: 50, transform: nil))
    context.setFillColor(rgba(0xeaf8ff, 0.94))
    context.fillPath()

    let dockItems: [(CGFloat, UInt32, CGFloat)] = [
        (274, 0x0ea5e9, 1.0),
        (382, 0x22c55e, 1.0),
        (490, 0xf8fafc, 1.0),
        (598, 0xf59e0b, 1.0),
        (706, 0x111827, 0.84),
    ]
    for item in dockItems {
        context.addPath(CGPath(roundedRect: CGRect(x: item.0, y: 194, width: 62, height: 62), cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.setFillColor(rgba(item.1, item.2))
        context.fillPath()
    }

    context.addPath(CGPath(roundedRect: CGRect(x: 478, y: 488, width: 68, height: 218), cornerWidth: 30, cornerHeight: 30, transform: nil))
    context.setFillColor(rgba(0xffffff, 1))
    context.fillPath()

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 512, y: 398))
    arrow.addLine(to: CGPoint(x: 348, y: 562))
    arrow.addLine(to: CGPoint(x: 452, y: 562))
    arrow.addLine(to: CGPoint(x: 452, y: 594))
    arrow.addLine(to: CGPoint(x: 572, y: 594))
    arrow.addLine(to: CGPoint(x: 572, y: 562))
    arrow.addLine(to: CGPoint(x: 676, y: 562))
    arrow.closeSubpath()
    context.addPath(arrow)
    context.setFillColor(rgba(0xffffff, 1))
    context.fillPath()

    context.addPath(CGPath(roundedRect: CGRect(x: 350, y: 324, width: 324, height: 68), cornerWidth: 34, cornerHeight: 34, transform: nil))
    context.setFillColor(rgba(0xffffff, 1))
    context.fillPath()

    guard let image = context.makeImage() else {
        fatalError("failed to render icon")
    }
    return image
}

func rgba(_ hex: UInt32, _ alpha: CGFloat) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255
    let green = CGFloat((hex >> 8) & 0xff) / 255
    let blue = CGFloat(hex & 0xff) / 255
    return CGColor(red: red, green: green, blue: blue, alpha: alpha)
}


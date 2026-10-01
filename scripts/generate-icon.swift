import AppKit
import Foundation

// Draw at full resolution; iconutil assembles the scaled iconset below.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext
cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let tile = CGRect(x: 48, y: 48, width: 928, height: 928)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 205, cornerHeight: 205, transform: nil)
cg.addPath(tilePath)
cg.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(36, 58, 65), color(14, 25, 34)] as CFArray,
    locations: [0, 1]
)!
cg.drawLinearGradient(gradient, start: CGPoint(x: 250, y: 960), end: CGPoint(x: 800, y: 40), options: [])

let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 276
cg.setLineCap(.round)
cg.setLineWidth(72)
cg.setStrokeColor(color(112, 148, 144, 0.28))
cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
cg.strokePath()

cg.setStrokeColor(color(48, 232, 160))
cg.addArc(center: center, radius: radius, startAngle: 225 * .pi / 180,
          endAngle: 490 * .pi / 180, clockwise: false)
cg.strokePath()

// A single needle keeps the mark legible even at 16 px in Finder.
cg.setStrokeColor(color(242, 250, 246))
cg.setLineWidth(40)
cg.move(to: center)
cg.addLine(to: CGPoint(x: 646, y: 638))
cg.strokePath()
cg.setFillColor(color(242, 250, 246))
cg.fillEllipse(in: CGRect(x: 468, y: 468, width: 88, height: 88))

NSGraphicsContext.restoreGraphicsState()
let master = output.appendingPathComponent("icon_512x512@2x.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: master)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
]
for (name, dimension) in variants {
    let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    NSGraphicsContext.current?.imageInterpolation = .high
    bitmap.draw(in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
    NSGraphicsContext.restoreGraphicsState()
    try scaled.representation(using: .png, properties: [:])!.write(
        to: output.appendingPathComponent(name))
}

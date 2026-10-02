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

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}

// Continuous-corner tile (superellipse) on the macOS 1024 grid: 824 pt body, 100 pt margins.
func squircle(_ rect: CGRect, exponent: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0..<steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let x = rect.midX + rect.width / 2 * copysign(pow(abs(cos(angle)), 2 / exponent), cos(angle))
        let y = rect.midY + rect.height / 2 * copysign(pow(abs(sin(angle)), 2 / exponent), sin(angle))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let body = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

// Standard drop shadow below the tile.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
cg.setFillColor(color(16, 24, 31))
cg.addPath(body)
cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(body)
cg.clip()
cg.drawLinearGradient(gradient([color(42, 56, 66), color(13, 19, 25)]),
                      start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Faint mint glow behind the rings for depth.
cg.drawRadialGradient(gradient([color(48, 232, 160, 0.09), color(48, 232, 160, 0)]),
                      startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                      endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [])
// Top-lit inner rim.
cg.addPath(body)
cg.setLineWidth(8)
cg.replacePathWithStrokedPath()
cg.clip()
cg.drawLinearGradient(gradient([color(255, 255, 255, 0.28), color(255, 255, 255, 0)]),
                      start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
cg.restoreGState()

// Two usage rings, like the menu bar account rings: thick enough to read at 16 px.
let center = CGPoint(x: 512, y: 512)
func ring(radius: CGFloat, width: CGFloat, fraction: CGFloat, colors: [CGColor]) {
    let start = CGFloat.pi / 2
    let end = start - fraction * 2 * .pi
    cg.setLineCap(.round)
    cg.setLineWidth(width)
    cg.setStrokeColor(color(255, 255, 255, 0.07))
    cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    cg.strokePath()

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0, 0, 0, 0.45))
    cg.setStrokeColor(colors[1])
    cg.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    cg.strokePath()
    cg.restoreGState()

    cg.saveGState()
    cg.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    cg.replacePathWithStrokedPath()
    cg.clip()
    cg.drawLinearGradient(gradient(colors), start: CGPoint(x: 512, y: center.y + radius + width),
                          end: CGPoint(x: 512, y: center.y - radius - width), options: [])
    cg.restoreGState()
}
ring(radius: 268, width: 92, fraction: 0.74, colors: [color(118, 250, 200), color(28, 196, 132)])
ring(radius: 148, width: 76, fraction: 0.42, colors: [color(255, 204, 128), color(255, 138, 61)])

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

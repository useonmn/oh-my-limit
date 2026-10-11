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

// Standard macOS drop shadow below the tile, lighter for a white body.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.22))
cg.setFillColor(color(255, 255, 255))
cg.addPath(body)
cg.fillPath()
cg.restoreGState()

// White tile with the faint top-to-bottom falloff of Apple's light icons.
cg.saveGState()
cg.addPath(body)
cg.clip()
cg.drawLinearGradient(gradient([color(255, 255, 255), color(240, 241, 245)]),
                      start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
cg.restoreGState()
// Hairline edge so the tile holds its shape on white backgrounds.
cg.saveGState()
cg.addPath(body)
cg.setLineWidth(3)
cg.setStrokeColor(color(0, 0, 0, 0.10))
cg.strokePath()
cg.restoreGState()

// Two usage rings, like the menu bar account rings: thick enough to read at 16 px.
let center = CGPoint(x: 512, y: 512)
func ring(radius: CGFloat, width: CGFloat, fraction: CGFloat, colors: [CGColor]) {
    let start = CGFloat.pi / 2
    let end = start - fraction * 2 * .pi
    cg.setLineCap(.round)
    cg.setLineWidth(width)
    cg.setStrokeColor(color(0, 0, 0, 0.06))
    cg.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    cg.strokePath()

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0, 0, 0, 0.12))
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
// Monochrome on white: a near-black main ring and a mid-gray secondary ring.
ring(radius: 262, width: 104, fraction: 0.74, colors: [color(58, 58, 60), color(28, 28, 30)])
ring(radius: 140, width: 88, fraction: 0.42, colors: [color(152, 152, 157), color(110, 110, 115)])

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

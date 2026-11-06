// Draws the Recast app icon (1024×1024 PNG): a waveform inside a two-arrow loop, on a teal-to-violet rounded
// square. Run by icon/make-icns.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = context
let cg = context.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// macOS icon grid: the shape is inset from the canvas and has rounded corners.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
cg.addPath(shape); cg.setFillColor(CGColor(red: 0.10, green: 0.25, blue: 0.40, alpha: 1)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(shape); cg.clip()
let background = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.07, green: 0.62, blue: 0.66, alpha: 1), CGColor(red: 0.42, green: 0.27, blue: 0.86, alpha: 1)] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(background, start: CGPoint(x: inset, y: size - inset), end: CGPoint(x: size - inset, y: inset), options: [])
let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(shine, start: CGPoint(x: size / 2, y: size - inset), end: CGPoint(x: size / 2, y: size / 2), options: [])
cg.restoreGState()

let center = CGPoint(x: size / 2, y: size / 2)
let white = CGColor(gray: 1, alpha: 0.96)

// The loop: two arcs, each ending in an arrowhead, like the Convert button's symbol.
let radius: CGFloat = 268
cg.setLineCap(.round)
cg.setLineWidth(40)
cg.setStrokeColor(white)
func arrow(from start: CGFloat, to end: CGFloat) {
    let a0 = start * .pi / 180, a1 = end * .pi / 180
    cg.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
    cg.strokePath()
    // Arrowhead at the end, pointing along the arc.
    let tip = CGPoint(x: center.x + cos(a1) * radius, y: center.y + sin(a1) * radius)
    let tangent = CGPoint(x: -sin(a1), y: cos(a1))
    let normal = CGPoint(x: cos(a1), y: sin(a1))
    let length: CGFloat = 92, width: CGFloat = 78
    let point = CGPoint(x: tip.x + tangent.x * length * 0.55, y: tip.y + tangent.y * length * 0.55)
    let back = CGPoint(x: tip.x - tangent.x * length * 0.45, y: tip.y - tangent.y * length * 0.45)
    let head = CGMutablePath()
    head.move(to: point)
    head.addLine(to: CGPoint(x: back.x + normal.x * width, y: back.y + normal.y * width))
    head.addLine(to: CGPoint(x: back.x - normal.x * width, y: back.y - normal.y * width))
    head.closeSubpath()
    cg.addPath(head); cg.setFillColor(white); cg.fillPath()
}
arrow(from: 205, to: 330)
arrow(from: 25, to: 150)

// The waveform: rounded bars, tallest in the middle.
let heights: [CGFloat] = [70, 150, 250, 330, 210, 290, 160, 90]
let barWidth: CGFloat = 30, gap: CGFloat = 20
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = center.x - total / 2
for height in heights {
    let bar = CGRect(x: x, y: center.y - height / 2, width: barWidth, height: height)
    cg.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    cg.setFillColor(white)
    cg.fillPath()
    x += barWidth + gap
}

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: out))

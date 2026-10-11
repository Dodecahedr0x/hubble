import AppKit

// Renders the 1024px app icon: gradient squircle with a "scope" of nested rings.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 0.12, green: 0.10, blue: 0.32, alpha: 1).cgColor,
              NSColor(red: 0.36, green: 0.22, blue: 0.75, alpha: 1).cgColor,
              NSColor(red: 0.93, green: 0.40, blue: 0.62, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// stars
srand48(7)
for _ in 0..<60 {
    let r = CGFloat(drand48() * 4 + 1.5)
    let p = CGPoint(x: rect.minX + CGFloat(drand48()) * rect.width, y: rect.minY + CGFloat(drand48()) * rect.height)
    ctx.setFillColor(NSColor.white.withAlphaComponent(CGFloat(drand48() * 0.5 + 0.2)).cgColor)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
}

let c = CGPoint(x: size / 2, y: size / 2)
// usage rings (like a disk map)
let rings: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
    (300, 0.0, 0.78, NSColor(red: 1.0, green: 0.78, blue: 0.45, alpha: 1)),
    (225, 0.1, 0.62, NSColor(red: 1.0, green: 0.55, blue: 0.75, alpha: 1)),
    (150, 0.25, 0.9, NSColor(red: 0.62, green: 0.85, blue: 1.0, alpha: 1)),
]
for (radius, from, to, color) in rings {
    ctx.setLineWidth(46); ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
    ctx.setStrokeColor(color.cgColor)
    let s = CGFloat.pi / 2 - from * 2 * .pi, e = CGFloat.pi / 2 - to * 2 * .pi
    ctx.addArc(center: c, radius: radius, startAngle: s, endAngle: e, clockwise: true); ctx.strokePath()
}
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - 42, y: c.y - 42, width: 84, height: 84))
ctx.restoreGState()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

// Draws the app icon: an original cat whose forehead carries an upvote arrow.
// No Snoo, no Reddit wordmark or alien silhouette; the orange is just a color.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt tile centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x7A1E05)); ctx.fillPath()
ctx.restoreGState()

// Tile gradient: warm orange at the top to deep ember at the bottom.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFF7A2E), rgb(0xB8300A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFD2A8, 0.45), rgb(0xFFD2A8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
ctx.restoreGState()

// Cat head: wide rounded face with two pointed ears.
let head = CGMutablePath()
head.addEllipse(in: CGRect(x: 232, y: 200, width: 560, height: 470))
func ear(_ pts: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.move(to: pts[0]); p.addLine(to: pts[1]); p.addLine(to: pts[2]); p.closeSubpath()
    return p.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10).union(p)
}
let leftEar = ear([CGPoint(x: 268, y: 540), CGPoint(x: 318, y: 790), CGPoint(x: 470, y: 645)])
let rightEar = ear([CGPoint(x: 756, y: 540), CGPoint(x: 706, y: 790), CGPoint(x: 554, y: 645)])
let headShape = CGPath(rect: .zero, transform: nil).union(head).union(leftEar).union(rightEar)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.4))
ctx.addPath(headShape); ctx.setFillColor(rgb(0xFFF6EE)); ctx.fillPath()
ctx.restoreGState()

// Inner ears.
for pts in [[CGPoint(x: 310, y: 590), CGPoint(x: 336, y: 730), CGPoint(x: 420, y: 650)],
            [CGPoint(x: 714, y: 590), CGPoint(x: 688, y: 730), CGPoint(x: 604, y: 650)]] {
    ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.addLine(to: pts[2]); ctx.closePath()
    ctx.setFillColor(rgb(0xFFC9A8)); ctx.fillPath()
}

// Upvote arrow on the forehead: chevron head plus a stem, in the tile's ember color.
let arrow = CGMutablePath()
let cx: CGFloat = 512, top: CGFloat = 600, w: CGFloat = 170
arrow.move(to: CGPoint(x: cx, y: top))
arrow.addLine(to: CGPoint(x: cx + w / 2, y: top - 95))
arrow.addLine(to: CGPoint(x: cx + w / 5, y: top - 95))
arrow.addLine(to: CGPoint(x: cx + w / 5, y: top - 185))
arrow.addLine(to: CGPoint(x: cx - w / 5, y: top - 185))
arrow.addLine(to: CGPoint(x: cx - w / 5, y: top - 95))
arrow.addLine(to: CGPoint(x: cx - w / 2, y: top - 95))
arrow.closeSubpath()
let roundedArrow = arrow.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10).union(arrow)
ctx.addPath(roundedArrow); ctx.setFillColor(rgb(0xD9430F)); ctx.fillPath()

// Eyes: content half-closed arcs, so the cat looks pleased about its karma.
ctx.setStrokeColor(rgb(0x2B1A14)); ctx.setLineWidth(26); ctx.setLineCap(.round)
for ex in [CGFloat(395), CGFloat(629)] {
    ctx.addArc(center: CGPoint(x: ex, y: 330), radius: 42, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
    ctx.strokePath()
}
// Nose and mouth.
ctx.setFillColor(rgb(0xE37A5C))
ctx.move(to: CGPoint(x: 512, y: 262)); ctx.addLine(to: CGPoint(x: 540, y: 300)); ctx.addLine(to: CGPoint(x: 484, y: 300)); ctx.closePath(); ctx.fillPath()
ctx.setLineWidth(14)
ctx.move(to: CGPoint(x: 512, y: 262)); ctx.addLine(to: CGPoint(x: 512, y: 240)); ctx.strokePath()
ctx.addArc(center: CGPoint(x: 478, y: 240), radius: 34, startAngle: 0, endAngle: -.pi * 0.9, clockwise: true); ctx.strokePath()
ctx.addArc(center: CGPoint(x: 546, y: 240), radius: 34, startAngle: .pi, endAngle: -.pi * 0.1, clockwise: false); ctx.strokePath()
// Whiskers.
ctx.setStrokeColor(rgb(0x2B1A14, 0.55)); ctx.setLineWidth(9)
for (sx, dir) in [(CGFloat(430), CGFloat(-1)), (CGFloat(594), CGFloat(1))] {
    for dy in [CGFloat(-26), 0, 26] {
        ctx.move(to: CGPoint(x: sx, y: 262 + dy)); ctx.addLine(to: CGPoint(x: sx + dir * 150, y: 262 + dy * 1.8)); ctx.strokePath()
    }
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

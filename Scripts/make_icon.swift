import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "/tmp/FrameBoardIcon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSGraphicsContext.current?.imageInterpolation = .high

// 1. macOS Squircle Canvas
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let outerPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 36
shadow.set()
NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.11, alpha: 1).setFill()
outerPath.fill()
NSGraphicsContext.restoreGraphicsState()

outerPath.addClip()
let bgGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.047, green: 0.055, blue: 0.105, alpha: 1),
    NSColor(calibratedRed: 0.086, green: 0.102, blue: 0.184, alpha: 1),
    NSColor(calibratedRed: 0.125, green: 0.098, blue: 0.196, alpha: 1)
])!
bgGrad.draw(in: bgRect, angle: -45)

// Ambient Amber + Cyan Glow
if let amberGlow = NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.25),
    NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.0)
]) {
    amberGlow.draw(fromCenter: NSPoint(x: 320, y: 690), radius: 15, toCenter: NSPoint(x: 320, y: 690), radius: 460, options: [])
}
if let cyanGlow = NSGradient(colors: [
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.22),
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.0)
]) {
    cyanGlow.draw(fromCenter: NSPoint(x: 710, y: 310), radius: 15, toCenter: NSPoint(x: 710, y: 310), radius: 440, options: [])
}

let rimPath = NSBezierPath(roundedRect: bgRect.insetBy(dx: 4, dy: 4), xRadius: 181, yRadius: 181)
rimPath.lineWidth = 5
NSColor.white.withAlphaComponent(0.14).setStroke()
rimPath.stroke()

// 2. 2x2 Storyboard Frame Grid (Centerpiece)
let tiles: [(NSRect, NSColor, NSColor)] = [
    (NSRect(x: 224, y: 530, width: 272, height: 220),
     NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.12, alpha: 1),
     NSColor(calibratedRed: 0.92, green: 0.42, blue: 0.15, alpha: 1)),
    (NSRect(x: 528, y: 530, width: 272, height: 220),
     NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.30),
     NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.85, alpha: 0.25)),
    (NSRect(x: 224, y: 274, width: 272, height: 220),
     NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.62, alpha: 0.28),
     NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.48, alpha: 0.25)),
    (NSRect(x: 528, y: 274, width: 272, height: 220),
     NSColor(calibratedRed: 0.66, green: 0.33, blue: 0.97, alpha: 0.30),
     NSColor(calibratedRed: 0.38, green: 0.24, blue: 0.82, alpha: 0.25))
]

for (idx, (rect, c1, c2)) in tiles.enumerated() {
    let p = NSBezierPath(roundedRect: rect, xRadius: 38, yRadius: 38)
    let g = NSGradient(colors: [c1, c2])!
    g.draw(in: p, angle: -35)
    p.lineWidth = idx == 0 ? 5 : 3
    NSColor.white.withAlphaComponent(idx == 0 ? 0.55 : 0.20).setStroke()
    p.stroke()

    // Timestamp pill inside each tile
    let pillRect = NSRect(x: rect.minX + 20, y: rect.minY + 20, width: 78, height: 22)
    let pill = NSBezierPath(roundedRect: pillRect, xRadius: 11, yRadius: 11)
    NSColor.black.withAlphaComponent(0.35).setFill()
    pill.fill()
}

// 3. Viewfinder Corner Brackets around Tile #1 (Hero Active Frame)
let hero = tiles[0].0.insetBy(dx: -10, dy: -10)
let bracketColor = NSColor.white.withAlphaComponent(0.95)
bracketColor.setStroke()
let bLen: CGFloat = 42
let corners: [(NSPoint, NSPoint, NSPoint)] = [
    (NSPoint(x: hero.minX, y: hero.maxY - bLen), NSPoint(x: hero.minX, y: hero.maxY), NSPoint(x: hero.minX + bLen, y: hero.maxY)),
    (NSPoint(x: hero.maxX - bLen, y: hero.maxY), NSPoint(x: hero.maxX, y: hero.maxY), NSPoint(x: hero.maxX, y: hero.maxY - bLen)),
    (NSPoint(x: hero.minX, y: hero.minY + bLen), NSPoint(x: hero.minX, y: hero.minY), NSPoint(x: hero.minX + bLen, y: hero.minY)),
    (NSPoint(x: hero.maxX - bLen, y: hero.minY), NSPoint(x: hero.maxX, y: hero.minY), NSPoint(x: hero.maxX, y: hero.minY + bLen))
]
for (p1, p2, p3) in corners {
    let bp = NSBezierPath()
    bp.lineWidth = 8
    bp.lineCapStyle = .round
    bp.lineJoinStyle = .round
    bp.move(to: p1)
    bp.line(to: p2)
    bp.line(to: p3)
    bp.stroke()
}

image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

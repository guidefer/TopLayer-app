import AppKit

// Draws the TopLayer app icon: three stacked layers on a dark glassy squircle,
// with the orange (Claude) and blue (Codex) identity colours in the lower layers.
// Usage: swift Scripts/make-icon.swift <output.png>

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824pt squircle centred on the 1024pt canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let background = CGGradient(colorsSpace: space, colors: [
    NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1).cgColor,
    NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

func glow(_ color: NSColor, at point: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: space, colors: [
        color.withAlphaComponent(0.55).cgColor, color.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
}
glow(.systemOrange, at: CGPoint(x: 300, y: 330), radius: 420)
glow(.systemBlue, at: CGPoint(x: 730, y: 330), radius: 420)

// Three layers, drawn bottom to top as flattened rounded diamonds.
func layer(centerY: CGFloat, top: NSColor, bottom: NSColor, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: 512, y: centerY)
    ctx.scaleBy(x: 1, y: 0.52)
    ctx.rotate(by: .pi / 4)
    let rect = CGRect(x: -215, y: -215, width: 430, height: 430)
    let path = CGPath(roundedRect: rect, cornerWidth: 70, cornerHeight: 70, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(bottom.withAlphaComponent(alpha).cgColor)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(path)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [
        top.withAlphaComponent(alpha).cgColor, bottom.withAlphaComponent(alpha).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: -215, y: 215), end: CGPoint(x: 215, y: -215), options: [])
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(10)
    ctx.strokePath()
    ctx.restoreGState()
}
layer(centerY: 370, top: NSColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1),
      bottom: NSColor(red: 0.08, green: 0.30, blue: 0.85, alpha: 1), alpha: 1)
layer(centerY: 505, top: NSColor(red: 1.0, green: 0.66, blue: 0.25, alpha: 1),
      bottom: NSColor(red: 0.93, green: 0.42, blue: 0.10, alpha: 1), alpha: 1)
layer(centerY: 640, top: NSColor(white: 1, alpha: 1), bottom: NSColor(white: 0.80, alpha: 1), alpha: 0.92)

// A soft highlight across the top, like light on glass.
let shine = CGGradient(colorsSpace: space, colors: [
    NSColor.white.withAlphaComponent(0.20).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

ctx.addPath(shape)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()
image.unlockFocus()

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output) \(rep.pixelsWide)x\(rep.pixelsHigh)")

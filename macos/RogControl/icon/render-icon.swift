// SPDX-License-Identifier: BSD-3-Clause-Clear
// Renders the ROG Control app icon ("Slash shard": a chamfered plate cut by three Slash segments) as Icon Composer layers
// and as one flat square for the .icns fallback. Layers are full-bleed 1024 squares; the system applies the mask.
//   swiftc -target x86_64-apple-macos14.0 render-icon.swift -o /tmp/render-icon && /tmp/render-icon <AppIcon.icon dir> <flat.png>
import AppKit

let N: CGFloat = 1024
let red = NSColor(srgbRed: 1.0, green: 0.13, blue: 0.24, alpha: 1)

func png(_ path: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(N), pixelsHigh: Int(N), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.translateBy(x: 0, y: N); c.scaleBy(x: 1, y: -1)     // top-left origin
    draw(c)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
func plate(_ c: CGContext) {
    let s = N * 0.60, x = (N - s) / 2, y = (N - s) / 2, cut = N * 0.12
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + s - cut, y: y)); p.addLine(to: CGPoint(x: x + s, y: y + cut))
    p.addLine(to: CGPoint(x: x + s, y: y + s)); p.addLine(to: CGPoint(x: x + cut, y: y + s)); p.addLine(to: CGPoint(x: x, y: y + s - cut))
    p.closeSubpath()
    c.addPath(p); c.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor); c.fillPath()
    c.addPath(p); c.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor); c.setLineWidth(N * 0.010); c.strokePath()
}
func slashes(_ c: CGContext, glow: Bool) {
    let h = N * 0.42, top = (N - h) / 2, k = N * 0.11, gap = N * 0.04     // bar height, slant, gap
    let widths: [CGFloat] = [0.075, 0.075, 0.11].map { $0 * N }            // horizontal thickness of each bar
    let alphas: [CGFloat] = [0.40, 0.68, 1.0]
    var x = (N - (widths.reduce(0, +) + gap * 2 + k)) / 2
    if glow { c.setShadow(offset: .zero, blur: N * 0.05, color: red.withAlphaComponent(0.55).cgColor) }
    for i in 0..<3 {
        let t = widths[i]
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x + k, y: top)); p.addLine(to: CGPoint(x: x + k + t, y: top))
        p.addLine(to: CGPoint(x: x + t, y: top + h)); p.addLine(to: CGPoint(x: x, y: top + h)); p.closeSubpath()
        let a = alphas[i]
        let solid = NSColor(srgbRed: 0.08 + (1.0 - 0.08) * a, green: 0.085 + (0.13 - 0.085) * a, blue: 0.10 + (0.24 - 0.10) * a, alpha: 1)
        c.addPath(p); c.setFillColor(solid.cgColor); c.fillPath()
        x += t + gap
    }
}

let dir = CommandLine.arguments[1], flat = CommandLine.arguments[2]
try? FileManager.default.createDirectory(atPath: dir + "/Assets", withIntermediateDirectories: true)
png(dir + "/Assets/plate.png") { plate($0) }
png(dir + "/Assets/slashes.png") { slashes($0, glow: false) }
// flat fallback for macOS 13-15: macOS grid (824 body, 100 margin), continuous corners, same gradient as the .icon fill
png(flat) { c in
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: NSColor(white: 0, alpha: 0.35).cgColor)
    c.addPath(shape); c.setFillColor(NSColor.black.cgColor); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(shape); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1).cgColor,
                       NSColor(srgbRed: 0.06, green: 0.065, blue: 0.075, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    c.translateBy(x: 100, y: 100); c.scaleBy(x: 824 / N, y: 824 / N)
    plate(c); slashes(c, glow: true)
    c.restoreGState()
}

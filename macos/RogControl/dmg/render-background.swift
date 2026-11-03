// SPDX-License-Identifier: BSD-3-Clause-Clear
// Draws the DMG window background (660 x 400 pt, 1x and 2x): dark ROG plate, a slanted-segment arrow from the app to
// Applications, one line of instructions. Icons sit at x 170 and 490, y 190 (set by scripts/build-dmg.sh).
import AppKit

func draw(scale: CGFloat, to path: String) {
    let W: CGFloat = 660, H: CGFloat = 400
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)          // top-left origin, points
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [NSColor(srgbRed: 0.075, green: 0.08, blue: 0.095, alpha: 1).cgColor,
                                NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
    // arrow: five slanted segments brightening toward Applications
    let red = (r: 1.0, g: 0.13, b: 0.24)
    for i in 0..<5 {
        let x = 268 + CGFloat(i) * 24, y: CGFloat = 178, w: CGFloat = 14, h: CGFloat = 24, k: CGFloat = 8
        let a = 0.25 + 0.75 * CGFloat(i) / 4
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x + k, y: y)); p.addLine(to: CGPoint(x: x + k + w, y: y))
        p.addLine(to: CGPoint(x: x + w, y: y + h)); p.addLine(to: CGPoint(x: x, y: y + h)); p.closeSubpath()
        c.addPath(p); c.setFillColor(NSColor(srgbRed: red.r, green: red.g, blue: red.b, alpha: a).cgColor); c.fillPath()
    }
    // flip back for text
    c.scaleBy(x: 1, y: -1); c.translateBy(x: 0, y: -H)
    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: tracking])
        let sz = a.size(); a.draw(at: NSPoint(x: (W - sz.width) / 2, y: H - y - sz.height))
    }
    text("ROG CONTROL", 13, .bold, NSColor(white: 0.93, alpha: 1), y: 36, tracking: 2.5)
    text("Drag ROG Control into Applications", 13, .regular, NSColor(white: 0.62, alpha: 1), y: 318)
    text("Needs AsusWmi.kext loaded through OpenCore", 11, .regular, NSColor(white: 0.40, alpha: 1), y: 342)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let out = CommandLine.arguments[1]
draw(scale: 1, to: out + "/background.png")
draw(scale: 2, to: out + "/background@2x.png")

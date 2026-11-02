// Renders AppIcon.icns: four deck tiles, with 1 and 3 highlighted.  usage: make_icon <out.iconset dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let colors: [NSColor] = [
    NSColor(srgbRed: 0.25, green: 0.66, blue: 1.00, alpha: 1), NSColor(srgbRed: 1.00, green: 0.62, blue: 0.15, alpha: 1),
    NSColor(srgbRed: 0.40, green: 0.86, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.88, green: 0.40, blue: 1.00, alpha: 1),
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(white: 0.08, alpha: 1).setFill(); bg.fill()
    let g = s * 0.05, area = s - 2 * inset - 3 * g, tile = area / 2
    for i in 0..<4 {
        let col = i % 2, row = i / 2
        let r = NSRect(x: inset + g + CGFloat(col) * (tile + g), y: s - inset - g - tile - CGFloat(row) * (tile + g), width: tile, height: tile)
        let p = NSBezierPath(roundedRect: r, xRadius: tile * 0.18, yRadius: tile * 0.18)
        let on = i == 0 || i == 3
        (on ? colors[i] : colors[i].withAlphaComponent(0.18)).setFill(); p.fill()
        colors[i].setStroke(); p.lineWidth = max(1, s * 0.012); p.stroke()
        let str = "\(i + 1)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tile * 0.6, weight: .heavy),
                                                    .foregroundColor: on ? NSColor.black : colors[i]]
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

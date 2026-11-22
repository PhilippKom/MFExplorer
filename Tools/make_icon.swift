// Draws the MFExplorer app icon and writes all sizes into the asset catalog.
// Run: swift Tools/make_icon.swift MFExplorer/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024   // design on a 1024 grid

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // Background tile (macOS icon grid: 824×824, inset 100)
    let tile = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.17, green: 0.42, blue: 0.90, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.33, green: 0.70, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.86, alpha: 1)])!
        .draw(in: tile, angle: -90)

    // A folder: tab + body
    func folder(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, alpha: CGFloat) {
        let tabPath = NSBezierPath(roundedRect: rect(x, y + h - 30, w * 0.42, 70), xRadius: 22 * s, yRadius: 22 * s)
        let body = NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: 30 * s, yRadius: 30 * s)
        NSGraphicsContext.saveGraphicsState()
        let fs = NSShadow()
        fs.shadowColor = NSColor.black.withAlphaComponent(0.18)
        fs.shadowOffset = NSSize(width: 0, height: -6 * s)
        fs.shadowBlurRadius = 14 * s
        fs.set()
        NSColor(calibratedWhite: 0.93, alpha: alpha).setFill()
        tabPath.fill()
        NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        // a thin line on the body, like a folder edge
        NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.92, alpha: 0.18 * alpha).setFill()
        NSBezierPath(roundedRect: rect(x + 30, y + h - 70, w - 60, 10), xRadius: 5 * s, yRadius: 5 * s).fill()
    }
    folder(x: 175, y: 230, w: 300, h: 230, alpha: 0.82)   // from
    folder(x: 549, y: 230, w: 300, h: 230, alpha: 1.0)    // to

    // Curved arrow from the left folder to the right one
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 330 * s, y: 530 * s))
    arrow.curve(to: NSPoint(x: 680 * s, y: 545 * s),
                controlPoint1: NSPoint(x: 380 * s, y: 790 * s),
                controlPoint2: NSPoint(x: 640 * s, y: 800 * s))
    arrow.lineWidth = 46 * s
    arrow.lineCapStyle = .round
    NSColor.white.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 600 * s, y: 600 * s))
    head.line(to: NSPoint(x: 700 * s, y: 505 * s))
    head.line(to: NSPoint(x: 745 * s, y: 640 * s))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 18 * s
    NSColor.white.setFill()
    head.fill()
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let entries: [(size: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [String] = []
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for e in entries {
    let px = e.size * e.scale
    let name = "icon_\(e.size)x\(e.size)\(e.scale == 2 ? "@2x" : "").png"
    let data = drawIcon(size: CGFloat(px)).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    images.append("""
        { "idiom" : "mac", "size" : "\(e.size)x\(e.size)", "scale" : "\(e.scale)x", "filename" : "\(name)" }
    """)
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
"""
try! contents.write(toFile: outDir + "/Contents.json", atomically: true, encoding: .utf8)
print("Icon written to \(outDir)")

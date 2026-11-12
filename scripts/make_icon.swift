// Draws the app icon and writes Resources/AppIcon.icns. Usage: swift scripts/make_icon.swift
import Cocoa

func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
    // Fills `path` with a top-to-bottom gradient, optionally casting a soft shadow.
    func fill(_ path: CGPath, top: CGColor, bottom: CGColor, shadow: (dy: CGFloat, blur: CGFloat, alpha: CGFloat)? = nil) {
        let box = path.boundingBox
        if let shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: shadow.dy * CGFloat(size) / 1024), blur: shadow.blur * CGFloat(size) / 1024,
                              color: color(0, 0, 0.05, shadow.alpha))
            context.addPath(path)
            context.setFillColor(bottom)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
        context.restoreGState()
    }
    // A hairline highlight along the top inside edge of `path`, for a sense of thickness.
    func rimLight(_ path: CGPath, alpha: CGFloat, width: CGFloat = 4) {
        let box = path.boundingBox
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.addPath(path)
        context.setLineWidth(width * 2)
        context.replacePathWithStrokedPath()
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, alpha), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.midY), options: [])
        context.restoreGState()
    }

    let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = rounded(plateRect, 185)

    // Dark plate; a bright desktop in front of two dimmer ones; one coloured name pill beneath.
    fill(plate, top: color(0.15, 0.16, 0.33), bottom: color(0.03, 0.03, 0.09), shadow: (-12, 28, 0.35))
    context.saveGState()
    context.addPath(plate)
    context.clip()
    let glow = CGGradient(colorsSpace: space, colors: [color(0.36, 0.38, 1.0, 0.50), color(0.36, 0.38, 1.0, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600), endRadius: 480, options: [])
    context.restoreGState()
    rimLight(plate, alpha: 0.28)

    // Two more desktops stacked behind, receding upward.
    let far = rounded(CGRect(x: 292, y: 500, width: 440, height: 290), 52)
    fill(far, top: color(0.36, 0.39, 0.62), bottom: color(0.24, 0.26, 0.46), shadow: (-8, 20, 0.3))
    rimLight(far, alpha: 0.35)
    let mid = rounded(CGRect(x: 252, y: 440, width: 520, height: 310), 56)
    fill(mid, top: color(0.60, 0.64, 0.86), bottom: color(0.40, 0.43, 0.68), shadow: (-8, 22, 0.35))
    rimLight(mid, alpha: 0.45)
    let front = rounded(CGRect(x: 212, y: 330, width: 600, height: 376), 62)
    fill(front, top: color(1, 1, 1), bottom: color(0.80, 0.85, 0.98), shadow: (-18, 44, 0.5))
    // A faint menu bar, so the card reads as a desktop rather than a sheet of paper.
    context.saveGState()
    context.addPath(front)
    context.clip()
    context.setFillColor(color(0.42, 0.47, 0.80, 0.20))
    context.fill(CGRect(x: 212, y: 672, width: 600, height: 34))
    context.restoreGState()

    // The name label, clipped onto the front desktop's lower edge.
    let pill = rounded(CGRect(x: 292, y: 250, width: 440, height: 150), 75)
    fill(pill, top: color(1.0, 0.72, 0.24), bottom: color(1.0, 0.44, 0.15), shadow: (-14, 30, 0.45))
    rimLight(pill, alpha: 0.6)
    context.setFillColor(color(1, 1, 1))
    context.fillEllipse(in: CGRect(x: 336, y: 295, width: 60, height: 60))
    context.addPath(rounded(CGRect(x: 428, y: 305, width: 250, height: 40), 20))
    context.fillPath()

    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

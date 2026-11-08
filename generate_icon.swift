import AppKit
import CoreGraphics
import Foundation

func drawPlumeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let scale = size / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    // 1. Gradaly-style Squircle Geometry (824x824 centered in 1024x1024)
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 190.0
    let squirclePath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft Outer Drop Shadow (matching Gradaly's clean macOS shadow)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -20),
        blur: 38,
        color: NSColor(calibratedRed: 0.18, green: 0.15, blue: 0.55, alpha: 0.35).cgColor
    )
    NSColor(calibratedRed: 0.31, green: 0.275, blue: 0.898, alpha: 1.0).setFill() // #4F46E5
    squirclePath.fill()
    ctx.restoreGState()

    // Clip to Squircle
    ctx.saveGState()
    squirclePath.addClip()

    // 2. Exact Gradaly Indigo/Mauve Gradient (#5B54F0 -> #4F46E5 -> #4338CA)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors: [CGColor] = [
        NSColor(calibratedRed: 0.263, green: 0.220, blue: 0.792, alpha: 1.0).cgColor, // #4338CA (Bottom)
        NSColor(calibratedRed: 0.310, green: 0.275, blue: 0.898, alpha: 1.0).cgColor, // #4F46E5 (Gradaly Core Mauve)
        NSColor(calibratedRed: 0.365, green: 0.333, blue: 0.945, alpha: 1.0).cgColor  // #5D55F1 (Top Highlight)
    ]
    let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors as CFArray, locations: bgLocations) {
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: 512, y: 100),
            end: CGPoint(x: 512, y: 924),
            options: []
        )
    }

    // Subtle luminous radial sheen in upper center
    let glowColors: [CGColor] = [
        NSColor(calibratedRed: 0.55, green: 0.52, blue: 1.0, alpha: 0.25).cgColor,
        NSColor(calibratedRed: 0.55, green: 0.52, blue: 1.0, alpha: 0.0).cgColor
    ]
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors as CFArray, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: 420, y: 760),
            startRadius: 0,
            endCenter: CGPoint(x: 420, y: 760),
            endRadius: 500,
            options: []
        )
    }

    // 3. Modern Geometric Stylized Plume + Fountain Nib Symbol
    // Build a single ultra-clean, iconic vector silhouette so we can draw both the
    // Gradaly 3D lavender extrusion layer (#CFD2F6) and the pure crisp white top layer (#FFFFFF).
    func makeStylizedPlumePath(offsetY: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()

        // Outer sleek aerodynamic wing of the Plume sweeping from bottom-left nib to top-right apex
        p.move(to: CGPoint(x: 265, y: 265 + offsetY))
        p.curve(
            to: CGPoint(x: 525, y: 735 + offsetY),
            controlPoint1: CGPoint(x: 270, y: 495 + offsetY),
            controlPoint2: CGPoint(x: 385, y: 665 + offsetY)
        )
        // Modern geometric razor notch 1 (upper edge)
        p.line(to: CGPoint(x: 475, y: 665 + offsetY))
        p.line(to: CGPoint(x: 565, y: 755 + offsetY))
        // Sweep to sharp modern apex (top-right)
        p.curve(
            to: CGPoint(x: 775, y: 785 + offsetY),
            controlPoint1: CGPoint(x: 635, y: 785 + offsetY),
            controlPoint2: CGPoint(x: 710, y: 790 + offsetY)
        )
        // Lower-right aerodynamic edge sweeping down
        p.curve(
            to: CGPoint(x: 655, y: 505 + offsetY),
            controlPoint1: CGPoint(x: 775, y: 675 + offsetY),
            controlPoint2: CGPoint(x: 730, y: 575 + offsetY)
        )
        // Modern geometric razor notch 2 (lower edge)
        p.line(to: CGPoint(x: 565, y: 520 + offsetY))
        p.line(to: CGPoint(x: 625, y: 465 + offsetY))
        // Continue curve to base of feather
        p.curve(
            to: CGPoint(x: 345, y: 315 + offsetY),
            controlPoint1: CGPoint(x: 560, y: 390 + offsetY),
            controlPoint2: CGPoint(x: 455, y: 335 + offsetY)
        )
        p.close()
        return p
    }

    // Draw central negative-space slit + fountain nib breather hole using a clipping mask
    func drawPlumeLayer(offsetY: CGFloat, color: NSColor) {
        ctx.saveGState()
        let bodyPath = makeStylizedPlumePath(offsetY: offsetY)

        // Subtract sleek central quill channel (gives it that ultra-modern Linear/Raycast/Gradaly geometric look)
        let slitPath = NSBezierPath()
        slitPath.move(to: CGPoint(x: 250, y: 250 + offsetY))
        slitPath.curve(
            to: CGPoint(x: 615, y: 625 + offsetY),
            controlPoint1: CGPoint(x: 365, y: 365 + offsetY),
            controlPoint2: CGPoint(x: 495, y: 505 + offsetY)
        )

        // First fill the main feather silhouette
        color.setFill()
        bodyPath.fill()

        // Draw dynamic swooshing tail / stem extending down-left to form a subtle "P" + Nib point
        let stemPath = NSBezierPath()
        stemPath.move(to: CGPoint(x: 235, y: 235 + offsetY))
        stemPath.curve(
            to: CGPoint(x: 590, y: 600 + offsetY),
            controlPoint1: CGPoint(x: 340, y: 345 + offsetY),
            controlPoint2: CGPoint(x: 470, y: 480 + offsetY)
        )
        stemPath.lineWidth = 34
        stemPath.lineCapStyle = .round
        color.setStroke()
        stemPath.stroke()

        // Carve inner fountain-pen channel in exact Gradaly Mauve so it looks precision-engineered
        let innerCut = NSBezierPath()
        innerCut.move(to: CGPoint(x: 355, y: 360 + offsetY))
        innerCut.curve(
            to: CGPoint(x: 655, y: 665 + offsetY),
            controlPoint1: CGPoint(x: 445, y: 455 + offsetY),
            controlPoint2: CGPoint(x: 555, y: 565 + offsetY)
        )
        innerCut.lineWidth = 22
        innerCut.lineCapStyle = .round
        NSColor(calibratedRed: 0.310, green: 0.275, blue: 0.898, alpha: 1.0).setStroke()
        innerCut.stroke()

        // Fountain nib breather circle at (425, 430)
        let holeRect = CGRect(x: 403, y: 408 + offsetY, width: 44, height: 44)
        let holePath = NSBezierPath(ovalIn: holeRect)
        NSColor(calibratedRed: 0.310, green: 0.275, blue: 0.898, alpha: 1.0).setFill()
        holePath.fill()

        ctx.restoreGState()
    }

    // Soft ambient shadow under the white emblem
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -22),
        blur: 32,
        color: NSColor(calibratedRed: 0.12, green: 0.09, blue: 0.48, alpha: 0.45).cgColor
    )
    drawPlumeLayer(offsetY: -14, color: NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.98, alpha: 1.0))
    ctx.restoreGState()

    // Gradaly-style 3D Extrusion Base Layer (#CFD2F6)
    drawPlumeLayer(offsetY: -13, color: NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.97, alpha: 1.0))

    // Pure Crisp White Top Layer (#FFFFFF)
    drawPlumeLayer(offsetY: 0, color: NSColor.white)

    // 4. Minimalist AI Sparkle Star (Top-Left of Feather, matching the 3D white/lavender aesthetic)
    drawModernSparkle(
        ctx: ctx,
        center: CGPoint(x: 310, y: 700),
        radius: 56,
        extrusionOffset: -8,
        extrusionColor: NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.97, alpha: 1.0),
        topColor: NSColor.white
    )

    drawModernSparkle(
        ctx: ctx,
        center: CGPoint(x: 695, y: 340),
        radius: 38,
        extrusionOffset: -6,
        extrusionColor: NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.97, alpha: 1.0),
        topColor: NSColor.white
    )

    // 5. Gradaly Outer Glass Bevel Rim (#817BF4)
    let outerBevel = NSBezierPath(roundedRect: iconRect.insetBy(dx: 4, dy: 4), xRadius: cornerRadius - 4, yRadius: cornerRadius - 4)
    outerBevel.lineWidth = 8
    NSColor(calibratedRed: 0.62, green: 0.60, blue: 0.99, alpha: 0.45).setStroke()
    outerBevel.stroke()

    ctx.restoreGState() // End squircle clip

    image.unlockFocus()
    return image
}

func drawModernSparkle(
    ctx: CGContext,
    center: CGPoint,
    radius: CGFloat,
    extrusionOffset: CGFloat,
    extrusionColor: NSColor,
    topColor: NSColor
) {
    func starPath(cy: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let top = CGPoint(x: center.x, y: cy + radius)
        let right = CGPoint(x: center.x + radius, y: cy)
        let bottom = CGPoint(x: center.x, y: cy - radius)
        let left = CGPoint(x: center.x - radius, y: cy)
        let inner = radius * 0.20

        path.move(to: top)
        path.curve(
            to: right,
            controlPoint1: CGPoint(x: center.x + inner, y: cy + inner),
            controlPoint2: CGPoint(x: center.x + inner, y: cy + inner)
        )
        path.curve(
            to: bottom,
            controlPoint1: CGPoint(x: center.x + inner, y: cy - inner),
            controlPoint2: CGPoint(x: center.x + inner, y: cy - inner)
        )
        path.curve(
            to: left,
            controlPoint1: CGPoint(x: center.x - inner, y: cy - inner),
            controlPoint2: CGPoint(x: center.x - inner, y: cy - inner)
        )
        path.curve(
            to: top,
            controlPoint1: CGPoint(x: center.x - inner, y: cy + inner),
            controlPoint2: CGPoint(x: center.x - inner, y: cy + inner)
        )
        path.close()
        return path
    }

    ctx.saveGState()
    extrusionColor.setFill()
    starPath(cy: center.y + extrusionOffset).fill()
    topColor.setFill()
    starPath(cy: center.y).fill()
    ctx.restoreGState()
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    try pngData.write(to: url)
}

let fm = FileManager.default
let baseDir = URL(fileURLWithPath: fm.currentDirectoryPath)
let resourcesDir = baseDir.appendingPathComponent("Resources")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let masterIcon = drawPlumeIcon(size: 1024)

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for spec in specs {
    let outURL = iconsetDir.appendingPathComponent(spec.name)
    try savePNG(masterIcon, to: outURL, pixelSize: spec.pixels)
}

let logoURL = resourcesDir.appendingPathComponent("PlumeLogo.png")
try savePNG(masterIcon, to: logoURL, pixelSize: 512)

print("Generated Gradaly-mauve Plume iconset and PlumeLogo.png successfully.")

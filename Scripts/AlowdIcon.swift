import AppKit

// The Alowd mark: a lowercase "d" whose bowl is an open ring and whose stem is
// the tallest bar of a level meter. The short bars read as a voice ("aloud"),
// the ring-and-stem reads as a lowercase d ("low d" — discreet, low key).
// Usage: swift AlowdIcon.swift <output.png> [--mark-only]

let arguments = CommandLine.arguments
let outputPath = arguments[1]
let markOnly = arguments.contains("--mark-only")

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

if !markOnly {
    // Rounded-square background. macOS "squircle" proportions: inset the art so
    // the icon matches the optical size of system icons in the Dock.
    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let background = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.35, green: 0.30, blue: 0.85, alpha: 1),
        ending: NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.42, alpha: 1)
    )!
    gradient.draw(in: background, angle: -90)

    // Soft top highlight so the face reads as glass rather than flat paint.
    background.setClip()
    NSGradient(
        starting: NSColor(white: 1, alpha: 0.18),
        ending: NSColor(white: 1, alpha: 0)
    )!.draw(in: NSRect(x: inset, y: size * 0.52, width: size - 2 * inset, height: size * 0.40), angle: -90)
}

let ink = NSColor.white
ink.setFill()
ink.setStroke()

// Geometry: everything sits on a shared baseline so the meter bars and the
// bowl of the d line up the way they would in a typeface.
let baseline = size * 0.315
let barWidth = size * 0.082
let radius = barWidth / 2
let gap = size * 0.055

let ringDiameter = size * 0.315
let stemHeight = size * 0.470
let strokeWidth = barWidth

// Total mark width: three meter bars, gaps, the ring, and the stem hugging it.
let markWidth = 3 * barWidth + 3 * gap + ringDiameter + strokeWidth * 0.5
let originX = (size - markWidth) / 2

// Meter bars: a small rhythm rather than a symmetric ramp, so it reads as
// speech rather than as a progress indicator.
let barHeights: [CGFloat] = [0.140, 0.265, 0.185].map { $0 * size }
for (index, height) in barHeights.enumerated() {
    let x = originX + CGFloat(index) * (barWidth + gap)
    let bar = NSBezierPath(
        roundedRect: NSRect(x: x, y: baseline, width: barWidth, height: height),
        xRadius: radius,
        yRadius: radius
    )
    bar.fill()
}

// The bowl of the d: an open ring, which doubles as a record indicator.
let ringX = originX + 3 * (barWidth + gap)
let ringRect = NSRect(
    x: ringX + strokeWidth / 2,
    y: baseline + strokeWidth / 2,
    width: ringDiameter - strokeWidth,
    height: ringDiameter - strokeWidth
)
let ring = NSBezierPath(ovalIn: ringRect)
ring.lineWidth = strokeWidth
ring.stroke()

// The ascender, sitting flush against the right of the bowl.
let stemX = ringX + ringDiameter - strokeWidth
let stem = NSBezierPath(
    roundedRect: NSRect(x: stemX, y: baseline, width: strokeWidth, height: stemHeight),
    xRadius: radius,
    yRadius: radius
)
stem.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon PNG")
}
try png.write(to: URL(fileURLWithPath: outputPath))

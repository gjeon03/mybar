// Renders Resources/AppIcon.icns: a tile with a frosted menu bar across the
// top and MyBar's bar dropping down from its chevron, revealing the hidden
// apps. Drawn on Apple's 1024 pt icon grid (824 pt tile).
// Usage: swift scripts/make-icon.swift [theme]   (themes: laver, rice, indigo)
// With MYBAR_ICON_PREVIEW=<path>, only writes a 1024 px preview there.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The icon's colours. The website shares the gimbap palette (laver, rice,
/// carrot, egg, spinach).
struct Theme {
  var tileBase: UInt32
  var tile: [UInt32]  // gradient, top to bottom
  var glow: UInt32
  var panel: (UInt32, UInt32)  // gradient, top to bottom
  var panelShadow: UInt32
  var chips: [(UInt32, UInt32)]
  var barGlyph: UInt32 = 0xFFFFFF
}

let themes: [String: Theme] = [
  "laver": Theme(
    tileBase: 0x14241D, tile: [0x3A6654, 0x1F382D, 0x0F1C16], glow: 0x9FE3B8,
    panel: (0xFFFDF7, 0xF3EBDA), panelShadow: 0x07110C,
    chips: [(0xFFA15C, 0xEA6A2A), (0xFFE07A, 0xF2B632), (0x8FD57A, 0x3E9B4F), (0xFF9DB4, 0xE0577F)]),
  "rice": Theme(
    tileBase: 0xEFE6D2, tile: [0xFFFBF1, 0xF6EEDC, 0xE9DDC2], glow: 0xF6C445,
    panel: (0x2C4A3D, 0x1B3027), panelShadow: 0x5A4A2A,
    chips: [(0xFFA15C, 0xEA6A2A), (0xFFE07A, 0xF2B632), (0x8FD57A, 0x3E9B4F), (0xFF9DB4, 0xE0577F)],
    barGlyph: 0x1B3027),
  "indigo": Theme(
    tileBase: 0x1B1E4B, tile: [0x4A4FE0, 0x2A2C8C, 0x121436], glow: 0x8A7CFF,
    panel: (0xFFFFFF, 0xE6E4FB), panelShadow: 0x05061A,
    chips: [(0xFFB347, 0xFF6A3D), (0x4FE3C1, 0x1FA2C9), (0xFF7EB3, 0xD6457F), (0x9BE15D, 0x38B26B)]),
]
let themeName = CommandLine.arguments.dropFirst().first ?? "laver"
let theme = themes[themeName] ?? themes["laver"]!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A rounded rectangle with continuous (squircle-like) corners, as macOS draws app tiles.
func squircle(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
  let path = NSBezierPath()
  let r = min(radius, rect.width / 2, rect.height / 2)
  // Corner control distance that approximates Apple's continuous curvature.
  let k: CGFloat = 1.12
  let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
  path.move(to: NSPoint(x: minX + r * k, y: maxY))
  path.line(to: NSPoint(x: maxX - r * k, y: maxY))
  path.curve(
    to: NSPoint(x: maxX, y: maxY - r * k), controlPoint1: NSPoint(x: maxX - r * 0.36, y: maxY),
    controlPoint2: NSPoint(x: maxX, y: maxY - r * 0.36))
  path.line(to: NSPoint(x: maxX, y: minY + r * k))
  path.curve(
    to: NSPoint(x: maxX - r * k, y: minY), controlPoint1: NSPoint(x: maxX, y: minY + r * 0.36),
    controlPoint2: NSPoint(x: maxX - r * 0.36, y: minY))
  path.line(to: NSPoint(x: minX + r * k, y: minY))
  path.curve(
    to: NSPoint(x: minX, y: minY + r * k), controlPoint1: NSPoint(x: minX + r * 0.36, y: minY),
    controlPoint2: NSPoint(x: minX, y: minY + r * 0.36))
  path.line(to: NSPoint(x: minX, y: maxY - r * k))
  path.curve(
    to: NSPoint(x: minX + r * k, y: maxY), controlPoint1: NSPoint(x: minX, y: maxY - r * 0.36),
    controlPoint2: NSPoint(x: minX + r * 0.36, y: maxY))
  path.close()
  return path
}

func withShadow(color: NSColor, blur: CGFloat, offsetY: CGFloat, _ draw: () -> Void) {
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = color
  shadow.shadowBlurRadius = blur
  shadow.shadowOffset = NSSize(width: 0, height: offsetY)
  shadow.set()
  draw()
  NSGraphicsContext.restoreGraphicsState()
}

/// Draws the icon in a 1024×1024 coordinate space.
func drawIcon() {
  let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = squircle(tile, radius: 185)

  // Tile with its drop shadow.
  withShadow(color: color(0x000000, 0.35), blur: 28, offsetY: -12) {
    color(theme.tileBase).setFill()
    tilePath.fill()
  }
  NSGraphicsContext.saveGraphicsState()
  tilePath.addClip()
  NSGradient(colors: theme.tile.map { color($0) }, atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    .draw(in: tile, angle: -70)
  // A soft glow behind the drop-down bar.
  NSGradient(colors: [color(theme.glow, 0.5), color(theme.glow, 0)])!
    .draw(fromCenter: NSPoint(x: 560, y: 470), radius: 0, toCenter: NSPoint(x: 560, y: 470), radius: 440, options: [])

  // Frosted menu bar across the top.
  let bar = NSRect(x: tile.minX, y: tile.maxY - 150, width: tile.width, height: 150)
  color(theme.barGlyph, 0.12).setFill()
  bar.fill()
  color(theme.barGlyph, 0.2).setFill()
  NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 3).fill()

  // Status items on the bar: a few simple glyphs, then MyBar's chevron.
  let glyphY = bar.midY
  color(theme.barGlyph, 0.55).setFill()
  NSBezierPath(ovalIn: NSRect(x: 214, y: glyphY - 19, width: 38, height: 38)).fill()
  NSBezierPath(roundedRect: NSRect(x: 290, y: glyphY - 18, width: 44, height: 36), xRadius: 10, yRadius: 10).fill()
  NSBezierPath(roundedRect: NSRect(x: 372, y: glyphY - 14, width: 70, height: 28), xRadius: 14, yRadius: 14).fill()
  color(theme.barGlyph, 0.9).setFill()
  NSBezierPath(roundedRect: NSRect(x: 760, y: glyphY - 13, width: 82, height: 26), xRadius: 13, yRadius: 13).fill()

  // MyBar's chevron, highlighted as if just clicked.
  let chevronCenter = NSPoint(x: 600, y: glyphY)
  color(theme.barGlyph, 0.22).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: chevronCenter.x - 50, y: chevronCenter.y - 50, width: 100, height: 100), xRadius: 26,
    yRadius: 26
  ).fill()
  let chevron = NSBezierPath()
  chevron.move(to: NSPoint(x: chevronCenter.x + 13, y: chevronCenter.y + 26))
  chevron.line(to: NSPoint(x: chevronCenter.x - 13, y: chevronCenter.y))
  chevron.line(to: NSPoint(x: chevronCenter.x + 13, y: chevronCenter.y - 26))
  chevron.lineWidth = 13
  chevron.lineCapStyle = .round
  chevron.lineJoinStyle = .round
  color(theme.barGlyph).setStroke()
  chevron.stroke()

  // The drop-down bar holding the revealed apps.
  let panel = NSRect(x: 192, y: 330, width: 640, height: 268)
  let panelPath = squircle(panel, radius: 62)
  withShadow(color: color(theme.panelShadow, 0.5), blur: 40, offsetY: -16) {
    color(theme.panel.1).setFill()
    panelPath.fill()
  }
  NSGraphicsContext.saveGraphicsState()
  panelPath.addClip()
  NSGradient(colors: [color(theme.panel.0), color(theme.panel.1)])!.draw(in: panel, angle: -90)
  NSGraphicsContext.restoreGraphicsState()
  // Pointer from the panel up to the chevron.
  let caret = NSBezierPath()
  caret.move(to: NSPoint(x: chevronCenter.x - 30, y: panel.maxY - 2))
  caret.line(to: NSPoint(x: chevronCenter.x, y: panel.maxY + 30))
  caret.line(to: NSPoint(x: chevronCenter.x + 30, y: panel.maxY - 2))
  caret.close()
  color(theme.panel.0).setFill()
  caret.fill()

  // App chips inside the bar.
  let chips = theme.chips
  let chipSize: CGFloat = 122
  let gap = (panel.width - chipSize * CGFloat(chips.count)) / CGFloat(chips.count + 1)
  for (index, chip) in chips.enumerated() {
    let rect = NSRect(
      x: panel.minX + gap + CGFloat(index) * (chipSize + gap), y: panel.midY - chipSize / 2, width: chipSize,
      height: chipSize)
    let path = squircle(rect, radius: 30)
    withShadow(color: color(theme.tileBase, 0.25), blur: 10, offsetY: -4) {
      color(chip.1).setFill()
      path.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [color(chip.0), color(chip.1)])!.draw(in: rect, angle: -90)
    // A small white glyph on each chip.
    color(0xFFFFFF, 0.92).setFill()
    let glyph = rect.insetBy(dx: 40, dy: 40)
    switch index {
    case 0: NSBezierPath(ovalIn: glyph).fill()
    case 1: NSBezierPath(roundedRect: glyph, xRadius: 9, yRadius: 9).fill()
    case 2:
      let heart = NSBezierPath()
      heart.move(to: NSPoint(x: glyph.midX, y: glyph.minY))
      heart.line(to: NSPoint(x: glyph.maxX, y: glyph.midY + 4))
      heart.line(to: NSPoint(x: glyph.midX, y: glyph.maxY))
      heart.line(to: NSPoint(x: glyph.minX, y: glyph.midY + 4))
      heart.close()
      heart.fill()
    default:
      NSBezierPath(roundedRect: glyph.insetBy(dx: 0, dy: 10), xRadius: 10, yRadius: 10).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  // Glassy highlight on the upper half and a hairline edge.
  NSGradient(colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
  NSGraphicsContext.restoreGraphicsState()
  color(0xFFFFFF, 0.12).setStroke()
  tilePath.lineWidth = 2
  tilePath.stroke()
}

func render(_ pixels: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  context.imageInterpolation = .high
  NSGraphicsContext.current = context
  let scale = CGFloat(pixels) / 1024
  context.cgContext.scaleBy(x: scale, y: scale)
  drawIcon()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

if let preview = ProcessInfo.processInfo.environment["MYBAR_ICON_PREVIEW"] {
  try render(1024).write(to: URL(fileURLWithPath: preview))
  exit(0)
}

for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    try render(base * scale).write(to: iconset.appendingPathComponent(name))
  }
}
try render(1024).write(to: root.appendingPathComponent("build/AppIcon-preview.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")

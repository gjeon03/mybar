import AppKit
import MyBarCore
import UniformTypeIdentifiers

/// Draws MyBar's menu bar icon in the chosen look (see `ControlIcon`).
enum ControlIconRenderer {
  /// Height of the icon in the menu bar, in points.
  static let height: CGFloat = 18

  static func image(for icon: ControlIcon, expanded: Bool) -> NSImage {
    let fallback = symbol(expanded ? "chevron.compact.right" : "chevron.compact.left")!
    switch icon {
    case .style(let id):
      let style = ControlIconStyle.style(withID: id)
      if style.id == "mybar" { return myBarGlyph(expanded: expanded) }
      return symbol(expanded ? style.expanded : style.collapsed) ?? fallback
    case .symbol(let name):
      // A filled variant, when there is one, marks the expanded state.
      return (expanded ? symbol(name + ".fill") : nil) ?? symbol(name) ?? fallback
    case .image(let template):
      guard let picture = CustomIconStore.load() else { return fallback }
      picture.isTemplate = template
      return picture
    }
  }

  static func symbol(_ name: String) -> NSImage? {
    guard !name.isEmpty, let image = NSImage(systemSymbolName: name, accessibilityDescription: "MyBar") else {
      return nil
    }
    let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    configured?.isTemplate = true
    return configured ?? image
  }

  /// A small menu bar with MyBar's chevron below it, like the app icon.
  private static func myBarGlyph(expanded: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: height), flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 17, height: 13), xRadius: 3.5, yRadius: 3.5)
      frame.lineWidth = 1.4
      frame.stroke()
      // The menu bar strip along the top.
      NSBezierPath(rect: NSRect(x: 2, y: 11.5, width: 16, height: 3.5)).fill()
      // The chevron, pointing the way the items go.
      let chevron = NSBezierPath()
      let tip: CGFloat = expanded ? 12.5 : 7.5
      let back: CGFloat = expanded ? 8.5 : 11.5
      chevron.move(to: NSPoint(x: back, y: 9.5))
      chevron.line(to: NSPoint(x: tip, y: 6.75))
      chevron.line(to: NSPoint(x: back, y: 4))
      chevron.lineWidth = 1.6
      chevron.lineCapStyle = .round
      chevron.lineJoinStyle = .round
      chevron.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }
}

/// Keeps a copy of the picture chosen for MyBar's icon.
enum CustomIconStore {
  private static var url: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("MyBar/ControlIcon.png")
  }

  /// Copies the picture at `source`, scaled to the menu bar's height.
  static func save(from source: URL) throws {
    guard let url, let picture = NSImage(contentsOf: source), picture.size.height > 0 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    // Twice the height in pixels, for Retina displays; at most 30 pt wide.
    let height = ControlIconRenderer.height
    let width = min(30, height * picture.size.width / picture.size.height)
    let pixels = NSSize(width: (width * 2).rounded(), height: height * 2)
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    picture.draw(in: NSRect(origin: .zero, size: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
  }

  static func load() -> NSImage? {
    guard let url, let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else { return nil }
    let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2))
    image.addRepresentation(rep)
    return image
  }

  static var allowedTypes: [UTType] { [.png, .jpeg, .pdf, .tiff, .heic, .svg] }
}

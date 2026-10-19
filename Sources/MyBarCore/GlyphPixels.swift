import CoreGraphics

/// What a captured menu bar item looks like, from its RGBA pixels.
public struct GlyphAnalysis: Equatable, Sendable {
  /// Average luminance (0...1) of the visible pixels.
  public let luminance: Double
  /// Strongest opacity (0...1) in the picture.
  public let maxAlpha: Double
  /// Whether the visible pixels are shades of one colour, like a template
  /// image, rather than a coloured icon.
  public let isMonochrome: Bool
}

/// Pixel-level helpers for captured menu bar items. Buffers hold 8-bit RGBA
/// with premultiplied alpha.
public enum GlyphPixels {
  /// Pixels fainter than this are ignored.
  static let visibleAlpha: UInt8 = 24
  /// Average saturation below which a picture counts as monochrome.
  static let monochromeSaturation = 0.12

  /// Analyses `rgba`, or returns nil when it is blank, which happens for
  /// windows that are not being drawn.
  public static func analyze(_ rgba: [UInt8]) -> GlyphAnalysis? {
    var luminance = 0.0
    var saturation = 0.0
    var count = 0
    var maxAlpha: UInt8 = 0
    for index in stride(from: 0, to: rgba.count - 3, by: 4) {
      let alpha = rgba[index + 3]
      maxAlpha = max(maxAlpha, alpha)
      guard alpha >= visibleAlpha else { continue }
      let a = Double(alpha)
      let r = min(1, Double(rgba[index]) / a)
      let g = min(1, Double(rgba[index + 1]) / a)
      let b = min(1, Double(rgba[index + 2]) / a)
      luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
      let high = max(r, g, b)
      let low = min(r, g, b)
      saturation += high > 0 ? (high - low) / high : 0
      count += 1
    }
    guard count >= 4 else { return nil }
    return GlyphAnalysis(
      luminance: luminance / Double(count), maxAlpha: Double(maxAlpha) / 255,
      isMonochrome: saturation / Double(count) < monochromeSaturation)
  }

  /// Scales opacity so the strongest pixel becomes fully opaque. Menu bars on
  /// inactive displays draw their items translucent.
  public static func boostAlpha(_ rgba: inout [UInt8]) {
    let maxAlpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }.max() ?? 0
    guard maxAlpha > 0, maxAlpha < 250 else { return }
    let factor = 255 / Double(maxAlpha)
    for index in rgba.indices {
      rgba[index] = UInt8(min(255, (Double(rgba[index]) * factor).rounded()))
    }
  }

  /// A glyph lifted off a picture of the menu bar.
  public struct LiftedGlyph: Equatable, Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int
  }

  /// Lifts what stands out from the menu bar inside `rect` of an opaque
  /// RGBA picture (`width`×`height`): each row's bar colour is read from
  /// `margin` pixels on both sides of the rect, and a pixel's opacity is
  /// how far it is from that colour. Nil when nothing stands out, or when
  /// what stands out runs across the whole rect (a neighbour's glyph got in).
  public static func lift(from rgba: [UInt8], width: Int, height: Int, rect: CGRect, margin: Int) -> LiftedGlyph? {
    let minX = max(0, Int(rect.minX))
    let maxX = min(width, Int(rect.maxX))
    let minY = max(0, Int(rect.minY))
    let maxY = min(height, Int(rect.maxY))
    guard maxX > minX, maxY > minY, rgba.count >= width * height * 4 else { return nil }
    let outWidth = maxX - minX
    let outHeight = maxY - minY
    var out = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
    var anything = false
    for y in minY..<maxY {
      // The bar's colour on this row, from just outside both sides of the
      // item. A neighbour's glyph can reach into the margin, so take the
      // median.
      var reds: [Double] = []
      var greens: [Double] = []
      var blues: [Double] = []
      for x in Array(max(0, minX - margin)..<minX) + Array(maxX..<min(width, maxX + margin)) {
        let index = (y * width + x) * 4
        reds.append(Double(rgba[index]))
        greens.append(Double(rgba[index + 1]))
        blues.append(Double(rgba[index + 2]))
      }
      guard !reds.isEmpty else { continue }
      func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
      let background = (median(reds), median(greens), median(blues))
      for x in minX..<maxX {
        let index = (y * width + x) * 4
        let r = Double(rgba[index])
        let g = Double(rgba[index + 1])
        let b = Double(rgba[index + 2])
        let distance = max(abs(r - background.0), abs(g - background.1), abs(b - background.2))
        // Small differences are the bar's own shading; a third of the full
        // range away from it counts as fully opaque.
        let alpha = min(1, max(0, (distance - 24) / 70))
        guard alpha > 0 else { continue }
        anything = true
        let target = ((y - minY) * outWidth + (x - minX)) * 4
        out[target] = UInt8(r * alpha)
        out[target + 1] = UInt8(g * alpha)
        out[target + 2] = UInt8(b * alpha)
        out[target + 3] = UInt8(alpha * 255)
      }
    }
    guard anything else { return nil }
    // A glyph reaching both edges is a neighbour's as much as this item's:
    // the frame was off from where the item is drawn.
    func reaches(_ column: Int) -> Bool {
      (0..<outHeight).contains { y in out[(y * outWidth + column) * 4 + 3] > 128 }
    }
    if reaches(0), reaches(outWidth - 1) { return nil }
    // A sliver isn't an item's glyph either: the frame was off and caught
    // only the edge of one.
    guard isPlausibleGlyph(out, width: outWidth, height: outHeight) else { return nil }
    return LiftedGlyph(pixels: out, width: outWidth, height: outHeight)
  }

  /// Whether an RGBA picture's opaque part is big enough to be an item's
  /// glyph rather than a sliver of one.
  public static func isPlausibleGlyph(_ rgba: [UInt8], width: Int, height: Int) -> Bool {
    guard width > 0, height > 0, rgba.count >= width * height * 4 else { return false }
    var opaque = 0
    var bounds = (minX: width, minY: height, maxX: -1, maxY: -1)
    for y in 0..<height {
      for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 128 {
        opaque += 1
        bounds = (min(bounds.minX, x), min(bounds.minY, y), max(bounds.maxX, x), max(bounds.maxY, y))
      }
    }
    guard opaque > 0 else { return false }
    let coverage = Double(opaque) / Double(width * height)
    let spanX = Double(bounds.maxX - bounds.minX + 1) / Double(width)
    let spanY = Double(bounds.maxY - bounds.minY + 1) / Double(height)
    return coverage >= 0.03 && spanX >= 0.2 && spanY >= 0.2
  }
}

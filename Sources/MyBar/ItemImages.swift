import AppKit
import MyBarCore
import ScreenCaptureKit

/// Captures pictures of menu bar items so they can be shown in MyBar's own
/// bar. The window server only draws status items that are on screen, so
/// items are captured whenever they are visible and the pictures are kept on
/// disk for the times they are pushed off screen.
@MainActor
final class ItemImages {
  /// Pictures older than this are refreshed by a capture pass.
  static let maximumAge: TimeInterval = 10 * 60

  private(set) var cache: [ItemKey: NSImage] = [:]
  /// Whether each captured item is drawn with light glyphs (as on a dark menu bar).
  private var lightGlyphs: [ItemKey: Bool] = [:]
  private var capturedAt: [ItemKey: Date] = [:]
  private var attemptedAt: [ItemKey: Date] = [:]
  private let directory: URL? = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
    .appendingPathComponent("MyBar/ItemImages", isDirectory: true)

  init() {
    loadFromDisk()
  }

  func image(for item: MenuBarItem) -> NSImage {
    if let image = cache[item.key] { return image }
    return Self.fallbackImage(for: item)
  }

  /// Whether any of `keys` has no picture yet or an outdated one.
  func needsCapture(_ keys: [ItemKey], now: Date = Date()) -> Bool {
    !keysNeedingCapture(keys, now: now).isEmpty
  }

  /// Those of `keys` with no picture or an outdated one. Items that could not
  /// be pictured (for example because macOS never draws them under the notch)
  /// are not retried until the same age has passed.
  func keysNeedingCapture(_ keys: [ItemKey], now: Date = Date()) -> Set<ItemKey> {
    Set(
      keys.filter { key in
        let dates = [capturedAt[key], attemptedAt[key]].compactMap { $0 }
        guard let latest = dates.max() else { return true }
        return now.timeIntervalSince(latest) > Self.maximumAge
      })
  }

  func markAttempted(_ keys: [ItemKey], at date: Date = Date()) {
    for key in keys { attemptedAt[key] = date }
  }

  /// Lets `keys` be tried again soon, after an attempt was cut short.
  func forgetAttempts(_ keys: [ItemKey]) {
    for key in keys { attemptedAt[key] = nil }
  }

  /// Whether most of `keys` were captured with light glyphs, so they should be
  /// shown on a dark background. Defaults to the system appearance.
  func prefersDarkBackground(for keys: [ItemKey]) -> Bool {
    let known = keys.compactMap { lightGlyphs[$0] }
    guard !known.isEmpty else {
      return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    return known.filter { $0 }.count * 2 >= known.count
  }

  /// Captures fresh images for those of `items` that are currently drawn on
  /// screen. Requires Screen Recording permission; without it the cache is
  /// left untouched and app icons are used instead.
  @discardableResult
  func refresh(_ items: [MenuBarItem]) async -> Set<ItemKey> {
    guard CGPreflightScreenCaptureAccess(), !items.isEmpty else { return [] }
    var captured: Set<ItemKey> = []
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
      // Copies of status items on other displays' menu bars. A display
      // without a notch often shows items the active one cannot.
      let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
      let mapping = MenuBarScanner.displayMapping()
      let menuBarWindows = content.windows.filter { window in
        window.windowLayer == statusLevel && window.isOnScreen && mapping.menuBarDisplay(of: window.frame) != nil
      }
      let menuBarFrames = menuBarWindows.map(\.frame)
      let candidates = items.map { item in
        let display = mapping.display(of: item.frame) ?? mapping.primary
        let primary = windows[item.window.windowID].flatMap { window in
          window.isOnScreen && mapping.menuBarDisplay(of: window.frame) == display ? window : nil
        }
        let mirror = mapping.mirror(of: item.frame, on: display, in: menuBarFrames).map { menuBarWindows[$0] }
        return (item.key, [primary, mirror].compactMap { $0 })
      }
      // Captures run concurrently; each one waits on the window server.
      await withTaskGroup(of: ItemKey?.self) { group in
        for (key, windows) in candidates where !windows.isEmpty {
          group.addTask { @MainActor in
            for window in windows where await self.capture(window, scale: Self.backingScale(at: window.frame), for: key)
            {
              return key
            }
            return nil
          }
        }
        for await key in group {
          if let key { captured.insert(key) }
        }
      }
    } catch {
      Log.scan.error("shareable content unavailable: \(error.localizedDescription)")
    }
    return captured
  }

  /// Captures one window; returns false when it failed or came back blank,
  /// which happens for items macOS is not drawing (for example under the notch).
  /// Pictures `items` from the screen (macOS 27+, where items have no
  /// windows of their own). The menu bar shows through each picture, so the
  /// glyph is lifted off it: the bar's colour, read just left and right of
  /// the item, is taken away and what stands out becomes a template glyph.
  func refreshFromScreen(_ items: [MenuBarItem]) async -> Set<ItemKey> {
    guard CGPreflightScreenCaptureAccess(), !items.isEmpty else { return [] }
    var captured: Set<ItemKey> = []
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      // MyBar's cover is over the menu bar while this runs; see through it.
      let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
      let mapping = MenuBarScanner.displayMapping()
      for bounds in mapping.displays {
        let displayItems = items.filter {
          $0.frame.minX >= bounds.minX && (mapping.display(of: $0.frame) ?? mapping.primary) == bounds
        }
        guard !displayItems.isEmpty,
          let display = content.displays.first(where: { CGDisplayBounds($0.displayID) == bounds })
        else { continue }
        let height = (displayItems.map(\.frame.maxY).max() ?? bounds.minY + 39) - bounds.minY
        let scale = Self.backingScale(at: displayItems[0].frame)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        config.width = Int(bounds.width * scale)
        config.height = Int(height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let stripPixels = Self.pixels(of: strip) else { continue }
        #if DEBUG
          if let out = ProcessInfo.processInfo.environment["MYBAR_DEBUG_STRIP"] {
            let rep = NSBitmapImageRep(cgImage: strip)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            Log.scan.info(
              "strip saved; items \(displayItems.map { "\($0.key.rawValue)@\(Int($0.frame.minX))+\(Int($0.frame.width))" }, privacy: .public)"
            )
          }
        #endif
        for item in displayItems {
          let rect = CGRect(
            x: (item.frame.minX - bounds.minX) * scale, y: (item.frame.minY - bounds.minY) * scale,
            width: item.frame.width * scale, height: item.frame.height * scale
          ).integral
          guard
            let glyph = GlyphPixels.lift(
              from: stripPixels, width: strip.width, height: strip.height, rect: rect, margin: Int(4 * scale)),
            let analysis = GlyphPixels.analyze(glyph.pixels),
            let image = Self.image(from: glyph.pixels, width: glyph.width, height: glyph.height)
          else { continue }
          store(
            image, size: item.frame.size, light: analysis.luminance > 0.5, template: analysis.isMonochrome,
            for: item.key)
          captured.insert(item.key)
        }
      }
    } catch {
      Log.scan.error("menu bar capture failed: \(error.localizedDescription)")
    }
    return captured
  }

  private func capture(_ window: SCWindow, scale: CGFloat, for key: ItemKey) async -> Bool {
    let config = SCStreamConfiguration()
    config.width = max(1, Int(window.frame.width * scale))
    config.height = max(1, Int(window.frame.height * scale))
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    config.captureResolution = .best
    let filter = SCContentFilter(desktopIndependentWindow: window)
    do {
      let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      guard var pixels = Self.pixels(of: captured), let analysis = GlyphPixels.analyze(pixels) else { return false }
      GlyphPixels.boostAlpha(&pixels)
      guard let image = Self.image(from: pixels, width: captured.width, height: captured.height) else { return false }
      store(
        image, size: window.frame.size, light: analysis.luminance > 0.5, template: analysis.isMonochrome, for: key)
      return true
    } catch {
      Log.scan.debug("capture failed for \(key.rawValue): \(error.localizedDescription)")
      return false
    }
  }

  // MARK: - Disk cache

  private struct Entry: Codable {
    var file: String
    var light: Bool
    var template: Bool?
    var capturedAt: Date
  }

  private var indexURL: URL? { directory?.appendingPathComponent("index.json") }
  private var entries: [String: Entry] = [:]

  /// Monochrome pictures are kept as template images, so the bar draws them
  /// in its own text colour whatever menu bar they were captured from.
  private func store(_ image: CGImage, size: CGSize, light: Bool, template: Bool, for key: ItemKey) {
    let now = Date()
    let picture = NSImage(cgImage: image, size: size)
    picture.isTemplate = template
    cache[key] = picture
    if template {
      lightGlyphs[key] = nil
    } else {
      lightGlyphs[key] = light
    }
    capturedAt[key] = now
    guard let directory, let indexURL else { return }
    let file = Self.fileName(for: key)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = size
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
      entries[key.rawValue] = Entry(file: file, light: light, template: template, capturedAt: now)
      try JSONEncoder().encode(entries).write(to: indexURL)
    } catch {
      Log.scan.error("could not save image for \(key.rawValue): \(error.localizedDescription)")
    }
  }

  private func loadFromDisk() {
    guard let directory, let indexURL, let data = try? Data(contentsOf: indexURL),
      let saved = try? JSONDecoder().decode([String: Entry].self, from: data)
    else { return }
    for (raw, entry) in saved {
      let url = directory.appendingPathComponent(entry.file)
      guard let rep = NSImageRep(contentsOf: url) as? NSBitmapImageRep else { continue }
      // Pictures saved before MyBar checked them can be slivers; drop those
      // so the app's icon is shown and the item pictured again.
      if let cgImage = rep.cgImage, let pixels = Self.pixels(of: cgImage),
        !GlyphPixels.isPlausibleGlyph(pixels, width: cgImage.width, height: cgImage.height)
      {
        continue
      }
      let image = NSImage(size: rep.size)
      image.addRepresentation(rep)
      image.isTemplate = entry.template ?? false
      let key = ItemKey(raw)
      entries[raw] = entry
      cache[key] = image
      if entry.template != true {
        lightGlyphs[key] = entry.light
      }
      capturedAt[key] = entry.capturedAt
    }
  }

  /// A file name derived from the key that is safe on disk.
  static func fileName(for key: ItemKey) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
    let safe = String(key.rawValue.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    return safe + ".png"
  }

  static func fallbackImage(for item: MenuBarItem) -> NSImage {
    if let pid = item.owner?.pid, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
      let copy = icon.copy() as? NSImage ?? icon
      copy.size = NSSize(width: 18, height: 18)
      return copy
    }
    return NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil) ?? NSImage()
  }

  /// Backing scale of the display showing `frame` (window-server coordinates).
  /// Captures are taken at that scale; asking for more leaves the picture
  /// small in a corner of a larger canvas.
  static func backingScale(at frame: CGRect) -> CGFloat {
    let display = MenuBarScanner.displayMapping().display(of: frame)
    let screen = display.flatMap(NSScreen.screen(withBounds:))
    return screen?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2
  }

  /// The image's pixels as premultiplied RGBA bytes.
  static func pixels(of image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? pixels : nil
  }

  static func image(from pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

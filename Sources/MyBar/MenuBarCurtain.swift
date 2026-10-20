import AppKit
import ScreenCaptureKit

/// Covers the menu bars with pictures of how they looked a moment ago,
/// so the shuffling MyBar does while rearranging items isn't seen. The cover
/// ignores the mouse, so synthesized drags and clicks reach the items below.
@MainActor
final class MenuBarCurtain {
  private var windows: [NSWindow] = []
  private var depth = 0

  /// Whether more than one caller holds the cover up.
  var isHeldByOthers: Bool { depth > 1 }

  /// Whether the cover is up (or on its way up).
  var isRaised: Bool { depth > 0 }

  /// Tells the cover it is still wanted, starting its time limit over.
  func keepUp() {
    if depth > 0 { startWatchdog() }
  }

  /// A picture of one display's menu bar and where it goes.
  private struct Cover {
    let frame: NSRect
    let image: CGImage
  }

  /// Pictures taken ahead of time, so covering doesn't wait for a capture.
  private var prepared: (date: Date, covers: [Cover])?
  private static let preparedLifetime: TimeInterval = 1.5

  /// Takes the pictures now, for a `raise()` that is likely to follow soon
  /// (for example while MyBar's bar is open).
  func prepare() async {
    let covers = await Self.captureCovers()
    if !covers.isEmpty { prepared = (Date(), covers) }
  }

  /// Covers the menu bar of every display: each one shows the status items,
  /// so each one would show the shuffling. Calls nest; the cover stays until
  /// the matching number of `lower()` calls.
  func raise() async {
    depth += 1
    guard depth == 1, Permissions.screenRecording else { return }
    let covers: [Cover]
    if let prepared, Date().timeIntervalSince(prepared.date) < Self.preparedLifetime {
      covers = prepared.covers
    } else {
      covers = await Self.captureCovers()
    }
    prepared = nil
    // The cover may have been lowered again while capturing.
    guard depth > 0, !covers.isEmpty else { return }
    for (index, cover) in covers.enumerated() {
      let window = index < windows.count ? windows[index] : Self.makeWindow()
      if index >= windows.count { windows.append(window) }
      let view = NSImageView(frame: NSRect(origin: .zero, size: cover.frame.size))
      view.image = NSImage(cgImage: cover.image, size: cover.frame.size)
      view.imageScaling = .scaleAxesIndependently
      window.contentView = view
      window.setFrame(cover.frame, display: true)
      window.orderFrontRegardless()
    }
    startWatchdog()
  }

  /// Waits until the window server shows the cover: ordered front, it only
  /// appears with a later screen refresh, and what it covers must not
  /// change before then.
  func waitUntilShown() async {
    let ids = Set(windows.filter(\.isVisible).map { CGWindowID($0.windowNumber) })
    guard !ids.isEmpty else { return }
    for _ in 0..<10 {
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
      let shown = list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }.filter(ids.contains)
      if shown.count == ids.count { break }
      await sleep(milliseconds: 10)
    }
    // Listed as on screen a frame or so before it is drawn.
    await sleep(milliseconds: 34)
  }

  /// Captures every display's menu bar at once.
  private static func captureCovers() async -> [Cover] {
    guard Permissions.screenRecording else { return [] }
    let statusWindows = MenuBarScanner.statusWindows()
    let mapping = MenuBarScanner.displayMapping()
    var targets: [(frame: NSRect, bounds: CGRect, height: CGFloat, scale: CGFloat)] = []
    for display in mapping.displays {
      guard let screen = NSScreen.screen(withBounds: display) else { continue }
      let itemHeight = statusWindows.filter { mapping.display(of: $0.frame) == display }.map(\.frame.height).max() ?? 0
      let height = max(menuBarHeight(of: screen), itemHeight)
      let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
      targets.append((frame, display, height, screen.backingScaleFactor))
    }
    return await withTaskGroup(of: (Int, CGImage?).self) { group in
      for (index, target) in targets.enumerated() {
        group.addTask { (index, await capture(display: target.bounds, height: target.height, scale: target.scale)) }
      }
      var images: [Int: CGImage] = [:]
      for await (index, image) in group {
        if let image { images[index] = image }
      }
      return targets.indices.compactMap { index in
        images[index].map { Cover(frame: targets[index].frame, image: $0) }
      }
    }
  }

  func lower() {
    guard depth > 0 else { return }
    depth -= 1
    guard depth == 0 else { return }
    watchdog?.cancel()
    for window in windows { window.orderOut(nil) }
  }

  /// However long MyBar is busy, the menu bar comes back after this.
  private static let maximumCover: Duration = .seconds(6)
  private var watchdog: Task<Void, Never>?

  private func startWatchdog() {
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      try? await Task.sleep(for: Self.maximumCover)
      guard !Task.isCancelled, let self, self.depth > 0 else { return }
      Log.app.error("menu bar covered too long; uncovering it")
      self.depth = 1
      self.lower()
    }
  }

  private static func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    // Above the picture of an item being dragged, which floats over the menu bar.
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) + 1)
    window.ignoresMouseEvents = true
    // The default show/hide animation briefly scales the window, which makes
    // the whole menu bar appear to lurch.
    window.animationBehavior = .none
    window.isOpaque = true
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    return window
  }

  /// Height of the menu bar, from the status-item windows on that display.
  private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
    let inset = screen.frame.maxY - screen.visibleFrame.maxY
    return max(inset, screen.safeAreaInsets.top, 24)
  }

  nonisolated private static func capture(display: CGRect, height: CGFloat, scale: CGFloat) async -> CGImage? {
    do {
      var watch = Stopwatch("curtain capture")
      defer { watch.lap("captured") }
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      watch.lap("content")
      guard let scDisplay = content.displays.first(where: { CGDisplayBounds($0.displayID) == display }) else {
        return nil
      }
      let config = SCStreamConfiguration()
      config.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: height)
      config.width = Int(display.width * scale)
      config.height = Int(height * scale)
      config.showsCursor = false
      let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    } catch {
      Log.move.error("menu bar capture failed: \(error.localizedDescription)")
      return nil
    }
  }
}

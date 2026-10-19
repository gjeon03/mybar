import AppKit

/// Keeps the pointer looking still while MyBar drives it.
///
/// Rearranging items takes the real cursor to the menu bar and back. Rather
/// than letting it jump around, or simply hiding it, MyBar hides it and shows
/// a picture of it where the person left it. Between MyBar's drags the
/// picture follows the mouse, so it never looks frozen for long.
@MainActor
final class CursorStandIn {
  private var depth = 0
  private var window: NSWindow?
  private var hotSpot = NSPoint.zero
  private var tracker: Timer?

  /// However long MyBar is busy, the real pointer comes back after this.
  private static let maximumStand: Duration = .seconds(6)
  private var watchdog: Task<Void, Never>?
  /// Bumped by each `raise()` that shows the picture.
  private var generation = 0

  /// Calls nest; the stand-in stays until the matching number of `lower()`
  /// calls. Returns once the picture is up and the real pointer hidden.
  func raise() async {
    depth += 1
    guard depth == 1 else { return }
    generation += 1
    let raised = generation
    let cursor = NSCursor.currentSystem ?? NSCursor.arrow
    let image = cursor.image
    hotSpot = cursor.hotSpot
    let window = self.window ?? Self.makeWindow()
    self.window = window
    let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    view.image = image
    window.contentView = view
    window.setContentSize(image.size)
    place(at: NSEvent.mouseLocation)
    window.orderFrontRegardless()
    // Hide the real pointer only once the picture is on screen, or for a
    // moment there is no pointer at all.
    await sleep(milliseconds: 20)
    // Lowered (and maybe raised again) meanwhile: that call owns the pointer.
    guard depth > 0, generation == raised else { return }
    Cursor.hide()
    tracker = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.follow() }
    }
    RunLoop.main.add(tracker!, forMode: .common)
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      try? await Task.sleep(for: Self.maximumStand)
      guard !Task.isCancelled, let self, self.depth > 0 else { return }
      Log.app.error("cursor stand-in shown too long; restoring the pointer")
      self.depth = 1
      self.lower()
    }
  }

  func lower() {
    guard depth > 0 else { return }
    depth -= 1
    guard depth == 0 else { return }
    watchdog?.cancel()
    tracker?.invalidate()
    tracker = nil
    Cursor.show()
    window?.orderOut(nil)
  }

  /// Moves the picture to the real pointer, unless MyBar is driving it, and
  /// keeps the real pointer hidden.
  private func follow() {
    Cursor.keepHidden()
    guard let location = EventDriver.personsCursorLocation() else { return }
    place(at: NSPoint(x: location.x, y: Self.flippedY(location.y)))
  }

  /// `location` in Cocoa screen coordinates.
  private func place(at location: NSPoint) {
    guard let window else { return }
    let size = window.frame.size
    let origin = NSPoint(x: location.x - hotSpot.x, y: location.y - (size.height - hotSpot.y))
    if window.frame.origin != origin { window.setFrameOrigin(origin) }
  }

  /// Converts a window-server y (top-left origin) to Cocoa's (bottom-left).
  private static func flippedY(_ y: CGFloat) -> CGFloat {
    (NSScreen.screens.first?.frame.maxY ?? 0) - y
  }

  private static func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
    window.ignoresMouseEvents = true
    window.animationBehavior = .none
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    return window
  }
}

/// Hides the pointer while MyBar moves it around on the person's behalf.
/// A background app may only hide the cursor after asking the window server
/// for permission to set it in the background.
enum Cursor {
  private typealias MainConnection = @convention(c) () -> Int32
  private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

  private static let allowed: Bool = {
    guard let handle = dlopen(nil, RTLD_NOW),
      let main = dlsym(handle, "CGSMainConnectionID"),
      let set = dlsym(handle, "CGSSetConnectionProperty")
    else { return false }
    let connection = unsafeBitCast(main, to: MainConnection.self)()
    let result = unsafeBitCast(set, to: SetProperty.self)(
      connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    return result == 0
  }()

  private typealias IsVisible = @convention(c) () -> Int32
  private static let isVisibleFunction: IsVisible? = dlsym(dlopen(nil, RTLD_NOW), "CGCursorIsVisible").map {
    unsafeBitCast($0, to: IsVisible.self)
  }

  /// Whether the pointer is showing, as far as can be told.
  static var isVisible: Bool { isVisibleFunction.map { $0() != 0 } ?? !hidden }

  /// How many times MyBar has hidden the pointer without showing it again.
  private static var hiddenCount = 0
  private static var hidden: Bool { hiddenCount > 0 }

  static func hide() {
    guard allowed, !hidden else { return }
    if CGDisplayHideCursor(CGMainDisplayID()) == .success { hiddenCount = 1 }
  }

  /// The window server shows a pointer hidden by a background app again when
  /// the mouse moves. Hides it again if so.
  static func keepHidden() {
    guard hidden, isVisible else { return }
    if CGDisplayHideCursor(CGMainDisplayID()) == .success { hiddenCount += 1 }
  }

  /// Shows the pointer, however many times it was hidden, and makes sure it
  /// is showing: a pointer left hidden is far worse than one shown early.
  static func show() {
    guard hidden else { return }
    for _ in 0..<hiddenCount { CGDisplayShowCursor(CGMainDisplayID()) }
    hiddenCount = 0
    for _ in 0..<4 where !isVisible { CGDisplayShowCursor(CGMainDisplayID()) }
  }
}

import AppKit
import os

enum Log {
  static let app = Logger(subsystem: "dev.gimbap.mybar", category: "app")
  static let scan = Logger(subsystem: "dev.gimbap.mybar", category: "scan")
  static let move = Logger(subsystem: "dev.gimbap.mybar", category: "move")
  static let perf = Logger(subsystem: "dev.gimbap.mybar", category: "perf")
}

/// Logs how long the steps of a user-facing flow take (category `perf`).
struct Stopwatch {
  let name: String
  private let start = Date()
  private var last = Date()

  init(_ name: String) {
    self.name = name
  }

  mutating func lap(_ step: String) {
    let now = Date()
    let lap = Int(now.timeIntervalSince(last) * 1000)
    let total = Int(now.timeIntervalSince(start) * 1000)
    let name = self.name
    Log.perf.info("\(name, privacy: .public) \(step, privacy: .public): \(lap) ms (\(total) ms)")
    last = now
  }
}

/// Names MyBar gives its own status items. On macOS 26 these also appear as
/// the window titles of the corresponding status-item windows.
enum OwnItemName {
  static let control = "MyBarControl"
  static let hidden = "MyBarHidden"
  static let alwaysHidden = "MyBarAlwaysHidden"
  static let groupPrefix = "MyBarGroup-"
  static let prefix = "MyBar"
}

extension CGRect {
  /// Converts a frame in window-server coordinates (origin at the top-left of
  /// the main display) to AppKit screen coordinates (origin at bottom-left).
  var flippedToAppKit: CGRect {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: minX, y: mainHeight - maxY, width: width, height: height)
  }

  /// Converts an AppKit screen frame to window-server coordinates.
  var flippedToWindowServer: CGRect {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: minX, y: mainHeight - maxY, width: width, height: height)
  }
}

func sleep(milliseconds: UInt64) async {
  try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

enum MenuState {
  /// Whether any pop-up menu (owned by another process) is currently on screen.
  static func isAnyMenuOpen() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
      return false
    }
    let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
    let ownPID = getpid()
    return list.contains { window in
      (window[kCGWindowLayer as String] as? Int) == menuLevel
        && (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID
    }
  }

  /// Whether the app that owns a menu bar item shows something that hangs
  /// from the menu bar near it, such as a popover or a panel, or any menu is
  /// open. Status items open popovers as ordinary windows of their app.
  static func isShowingUI(of ownerPID: pid_t?, near itemFrame: CGRect) -> Bool {
    if isAnyMenuOpen() { return true }
    guard let ownerPID,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    let near = itemFrame.insetBy(dx: -700, dy: 0)
    return list.contains { window in
      guard (window[kCGWindowOwnerPID as String] as? pid_t) == ownerPID,
        (window[kCGWindowLayer as String] as? Int) != statusLevel,
        (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds),
        frame.width > 40, frame.height > 40
      else { return false }
      // Hangs from the menu bar: starts just below it, near the item.
      return frame.minY <= itemFrame.maxY + 40 && frame.minY >= itemFrame.minY - 2
        && frame.maxX >= near.minX && frame.minX <= near.maxX
    }
  }
}

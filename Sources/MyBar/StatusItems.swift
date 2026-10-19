import AppKit
import MyBarCore

/// How much of the hidden menu bar is currently expanded.
enum RevealLevel: Int, Comparable {
  case none = 0
  case hidden = 1
  case all = 2

  static func < (lhs: RevealLevel, rhs: RevealLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Owns MyBar's control icon and the two divider items.
///
/// A collapsed divider is made far wider than any screen, which pushes every
/// item to its left off the edge of the display. Expanding it shrinks it back
/// to a thin separator so those items return to the menu bar.
@MainActor
final class StatusItems {
  static let collapsedLength: CGFloat = 10_000
  static let expandedLength: CGFloat = 14

  let control: NSStatusItem
  private(set) var hiddenDivider: NSStatusItem
  private(set) var alwaysHiddenDivider: NSStatusItem

  var onControlClick: ((NSEvent) -> Void)?

  /// Requested reveal levels from independent sources; the widest one wins.
  private var levels: [String: RevealLevel] = [:]
  private(set) var effectiveLevel: RevealLevel = .none

  init() {
    Self.seedPositions()
    control = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    control.autosaveName = OwnItemName.control
    hiddenDivider = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
    hiddenDivider.autosaveName = OwnItemName.hidden
    alwaysHiddenDivider = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
    alwaysHiddenDivider.autosaveName = OwnItemName.alwaysHidden

    configureControl()
    configureDivider(hiddenDivider, identifier: OwnItemName.hidden, dashed: false)
    configureDivider(alwaysHiddenDivider, identifier: OwnItemName.alwaysHidden, dashed: true)
    apply()
  }

  /// Preferred positions are distances from the right edge of the screen to
  /// the item's right edge. On first launch MyBar puts its icon and the hidden
  /// divider just left of the system items, and the always-hidden divider at
  /// the far left, so existing items start out in the Hidden section. Keeping
  /// the divider near the right leaves room to bring a hidden item on screen
  /// when it is opened from the MyBar Bar.
  static let controlPosition = 180
  static let groupPosition = 190
  static let hiddenPosition = 200
  static let alwaysHiddenPosition = 20_000

  private static func seedPositions() {
    seedPosition(controlPosition, for: OwnItemName.control)
    seedPosition(hiddenPosition, for: OwnItemName.hidden)
    seedPosition(alwaysHiddenPosition, for: OwnItemName.alwaysHidden)
  }

  /// Sets an item's initial position unless macOS already remembers one.
  static func seedPosition(_ position: Int, for autosaveName: String) {
    let defaults = UserDefaults.standard
    let key = "NSStatusItem Preferred Position \(autosaveName)"
    if defaults.object(forKey: key) == nil {
      defaults.set(position, forKey: key)
    }
    defaults.removeObject(forKey: "NSStatusItem Visible \(autosaveName)")
  }

  /// Puts the divider named `autosaveName` at `position` (see `seedPositions`)
  /// without dragging it: macOS places a new status item where its saved
  /// position says, so the divider is removed and added again. Used when an
  /// item behind the notch can't be picked up: moving the divider past the
  /// item changes its section all the same.
  func relocateDivider(_ autosaveName: String, toPosition position: Int) {
    let isHidden = autosaveName == OwnItemName.hidden
    NSStatusBar.system.removeStatusItem(isHidden ? hiddenDivider : alwaysHiddenDivider)
    // Removing the item saves its position; set the new one afterwards.
    UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position \(autosaveName)")
    let item = NSStatusBar.system.statusItem(withLength: Self.expandedLength)
    item.autosaveName = autosaveName
    configureDivider(item, identifier: autosaveName, dashed: !isHidden)
    if isHidden { hiddenDivider = item } else { alwaysHiddenDivider = item }
    apply()
  }

  // MARK: - Reveal levels

  func setLevel(_ level: RevealLevel, for source: String) {
    levels[source] = level == .none ? nil : level
    apply()
  }

  func level(for source: String) -> RevealLevel { levels[source] ?? .none }

  private func apply() {
    let level = levels.values.max() ?? .none
    effectiveLevel = level
    if MenuBarSystem.usesAgent {
      // Dividers don't push anything off screen there; items are concealed
      // instead (see `Concealer`), so they are left out.
      hiddenDivider.length = 0
      alwaysHiddenDivider.length = 0
      hiddenDivider.button?.image = nil
      alwaysHiddenDivider.button?.image = nil
      updateControlImage()
      return
    }
    hiddenDivider.length = level >= .hidden ? Self.expandedLength : Self.collapsedLength
    alwaysHiddenDivider.length = level == .all ? Self.expandedLength : Self.collapsedLength
    hiddenDivider.button?.image = level >= .hidden ? Self.dividerImage(dashed: false) : nil
    alwaysHiddenDivider.button?.image = level == .all ? Self.dividerImage(dashed: true) : nil
    updateControlImage()
  }

  // MARK: - Appearance

  private func configureControl() {
    guard let button = control.button else { return }
    button.setAccessibilityIdentifier(OwnItemName.control)
    button.setAccessibilityLabel("MyBar")
    button.toolTip = "MyBar — click to show hidden items, ⌥-click to include always hidden"
    button.target = self
    button.action = #selector(controlClicked(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    updateControlImage()
  }

  private func configureDivider(_ item: NSStatusItem, identifier: String, dashed: Bool) {
    guard let button = item.button else { return }
    button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityLabel(dashed ? "MyBar always hidden divider" : "MyBar hidden divider")
    button.appearsDisabled = true
  }

  /// The look of MyBar's icon (see `ControlIcon`).
  var controlIcon: ControlIcon = .default {
    didSet { updateControlImage() }
  }

  private func updateControlImage() {
    control.button?.image = ControlIconRenderer.image(for: controlIcon, expanded: effectiveLevel != .none)
  }

  @objc private func controlClicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    onControlClick?(event)
  }

  private static func dividerImage(dashed: Bool) -> NSImage {
    let size = NSSize(width: 6, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: rect.midX, y: 1))
      path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1))
      path.lineWidth = 1.5
      if dashed {
        path.setLineDash([2, 2], count: 2, phase: 0)
      }
      NSColor.black.withAlphaComponent(0.6).setStroke()
      path.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }

  /// The control item's frame in window-server coordinates.
  var controlFrame: CGRect? {
    guard let window = control.button?.window else { return nil }
    return window.frame.flippedToWindowServer
  }
}

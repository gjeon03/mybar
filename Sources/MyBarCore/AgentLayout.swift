import CoreGraphics

/// Rules for the menu bar drawn by MenuBarAgent (macOS 27 and later).
///
/// There, status items are no longer windows of their own: MenuBarAgent
/// draws them all, and when they don't all fit between the notch and the
/// right edge it folds the leftmost ones behind its chevron ("Show Hidden
/// Menu Bar Items").
public enum AgentLayout {
  /// Whether an item at `frame` is folded behind the chevron. Folded items
  /// are reported squeezed together over and left of the chevron (or, while
  /// it is open, drawn in the empty space left of the notch); items that are
  /// shown start right of it.
  public static func isFolded(_ frame: CGRect, chevron: CGRect?) -> Bool {
    guard let chevron else { return false }
    return frame.minX < chevron.maxX - 1
  }
}

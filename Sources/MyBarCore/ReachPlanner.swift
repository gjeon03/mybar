import CoreGraphics

/// Plans how to bring an item that macOS isn't drawing (behind the notch or
/// beyond it) to where it can be dragged.
///
/// Only items that are drawn can be picked up, but a dragged item can be
/// dropped anywhere the cursor can go, including over items that aren't
/// drawn. Dropping drawn items just left of the target shortens the run of
/// items to its right, so the target slides right, item by item, until it is
/// clear of the notch.
public enum ReachPlanner {
  /// How far `target` still has to move right to be reachable, or nil when it
  /// can't be helped by sliding (it is past the right edge).
  public static func shortfall(of target: CGRect, geometry: MenuBarGeometry) -> CGFloat? {
    if geometry.isReachable(target) { return 0 }
    guard target.maxX <= geometry.span.upperBound else { return nil }
    let leftmost = geometry.firstDrawnX
    return max(leftmost - target.minX, 0) + 2
  }

  /// Items wider than this (text readouts and the like) are a last resort:
  /// the menu bar often doesn't take a drag of one dropped among icons.
  static let comfortableWidth: CGFloat = 52

  /// Index of the item in `candidates` to drop left of `target`: a reachable
  /// item to the target's right. Prefers the narrowest item that covers the
  /// remaining shortfall, otherwise the widest, to keep the number of drags
  /// low, and icon-sized items over wide ones.
  public static func itemToShift(
    leftOf target: CGRect, candidates: [CGRect], geometry: MenuBarGeometry
  ) -> Int? {
    guard let needed = shortfall(of: target, geometry: geometry), needed > 0 else { return nil }
    let reachable = candidates.indices.filter { index in
      let frame = candidates[index]
      return frame.minX >= target.maxX - 1 && geometry.isReachable(frame)
    }
    let iconSized = reachable.filter { candidates[$0].width <= comfortableWidth }
    let usable = iconSized.isEmpty ? reachable : iconSized
    let covering = usable.filter { candidates[$0].width >= needed }
    if let best = covering.min(by: { candidates[$0].width < candidates[$1].width }) { return best }
    return usable.max { candidates[$0].width < candidates[$1].width }
  }

  /// Where to drop an item of width `carried`, picked up from the right of
  /// `target`, so the menu bar inserts it just left of `target`. Once the
  /// item is lifted, everything to its left closes the gap and the target
  /// shifts right by that width, so the point is just inside the shifted
  /// target's left edge. It is never left of the target's original left edge
  /// either, so even if the target doesn't shift, the item can't land beyond
  /// a divider next to it. Nil when the cursor can't get there.
  public static func dropPoint(leftOf target: CGRect, carrying carried: CGFloat, geometry: MenuBarGeometry) -> CGPoint?
  {
    let point = CGPoint(x: target.minX + carried + 3, y: target.midY)
    return geometry.isReachable(point) ? point : nil
  }
}

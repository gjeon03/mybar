import CoreGraphics

/// Relates menu bar frames on different displays.
///
/// With several displays every one of them shows a menu bar. The real
/// status-item windows live on the display whose menu bar is active, and the
/// other displays show copies. All of them keep the same distance from the
/// right edge of their display, so a frame on one display maps to another by
/// that distance. Frames are in window-server
/// coordinates (origin at the top left of the primary display).
public struct DisplayMapping: Equatable, Sendable {
  /// Bounds of the primary display (the origin of window-server coordinates).
  public let primary: CGRect
  /// Bounds of every active display, including the primary one.
  public let displays: [CGRect]

  /// Frames this close to the top of a display are considered part of its menu bar.
  static let menuBarDepth: CGFloat = 60
  static let tolerance: CGFloat = 3

  public init(primary: CGRect, displays: [CGRect]) {
    self.primary = primary
    self.displays = displays
  }

  /// The display whose menu bar contains `frame`, if any.
  public func menuBarDisplay(of frame: CGRect) -> CGRect? {
    displays.first { display in
      frame.midX >= display.minX && frame.midX <= display.maxX
        && frame.midY >= display.minY && frame.midY <= display.minY + Self.menuBarDepth
    }
  }

  /// The display whose menu bar most of `frames` lie in. Accessibility
  /// reports every menu bar extra on the menu bar that is currently active,
  /// including items pushed off its edge, so the display is decided by the
  /// items that are on screen.
  public func activeDisplay(of frames: [CGRect]) -> CGRect {
    var votes: [Int: Int] = [:]
    for frame in frames {
      guard let display = menuBarDisplay(of: frame), let index = displays.firstIndex(of: display) else { continue }
      votes[index, default: 0] += 1
    }
    guard let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else {
      return primary
    }
    return displays[best.key]
  }

  /// `frame`, from the menu bar of `display`, moved onto the primary display's
  /// menu bar by keeping its distance from the right edge.
  public func toPrimary(_ frame: CGRect, from display: CGRect) -> CGRect {
    convert(frame, from: display, to: primary)
  }

  /// `frame`, from the menu bar of `source`, moved onto the menu bar of
  /// `destination` by keeping its distance from the right edge.
  public func convert(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
    if source == destination { return frame }
    return frame.offsetBy(dx: destination.maxX - source.maxX, dy: destination.minY - source.minY)
  }

  /// The display whose menu bar row `frame` is in. Unlike `menuBarDisplay(of:)`
  /// this also places frames pushed off the side of a display, preferring the
  /// display that horizontally contains the frame.
  public func display(of frame: CGRect) -> CGRect? {
    let row = displays.filter { display in
      frame.midY >= display.minY && frame.midY <= display.minY + Self.menuBarDepth
    }
    return row.first { $0.minX <= frame.midX && frame.midX <= $0.maxX }
      ?? row.min { abs($0.midX - frame.midX) < abs($1.midX - frame.midX) }
  }

  /// Index of the window in `candidates` that is a copy, on another display,
  /// of the window at `frame` on `source`.
  public func mirror(of frame: CGRect, on source: CGRect, in candidates: [CGRect]) -> Int? {
    let fromRight = source.maxX - frame.maxX
    return candidates.firstIndex { candidate in
      guard let display = menuBarDisplay(of: candidate), display != source else { return false }
      return abs((display.maxX - candidate.maxX) - fromRight) <= Self.tolerance
        && abs(candidate.width - frame.width) <= Self.tolerance
    }
  }
}

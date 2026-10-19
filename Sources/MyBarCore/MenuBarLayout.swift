import CoreGraphics
import Foundation

/// The section of the menu bar an item lives in, from right to left.
public enum MenuBarSection: String, Codable, CaseIterable, Sendable, Identifiable {
  case visible
  case hidden
  case alwaysHidden

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .visible: "Visible"
    case .hidden: "Hidden"
    case .alwaysHidden: "Always Hidden"
    }
  }
}

/// Frames of MyBar's two divider items. Either may be missing (for example
/// while the window server has not placed them yet).
public struct DividerFrames: Equatable, Sendable {
  public var hidden: CGRect?
  public var alwaysHidden: CGRect?

  public init(hidden: CGRect?, alwaysHidden: CGRect?) {
    self.hidden = hidden
    self.alwaysHidden = alwaysHidden
  }
}

public enum MenuBarLayout {
  /// Classifies an item by its position relative to the dividers.
  /// Items to the right of the hidden divider are visible; items to the left
  /// of the always-hidden divider are always hidden; the rest are hidden.
  public static func section(of frame: CGRect, dividers: DividerFrames) -> MenuBarSection {
    if let always = dividers.alwaysHidden, frame.midX < always.midX {
      return .alwaysHidden
    }
    guard let hidden = dividers.hidden else { return .visible }
    return frame.midX > hidden.midX ? .visible : .hidden
  }

  /// Candidate cursor positions for dropping a dragged item into `section`,
  /// most precise first. Dropping on the left part of a divider inserts the
  /// item to its left; dropping on the right part inserts it to its right.
  public static func dropPoints(into section: MenuBarSection, dividers: DividerFrames) -> [CGPoint] {
    func leftPart(_ frame: CGRect) -> [CGPoint] {
      let inset = min(4, frame.width / 4)
      return [
        CGPoint(x: frame.minX + inset, y: frame.midY),
        CGPoint(x: frame.minX - 6, y: frame.midY),
      ]
    }
    func rightPart(_ frame: CGRect) -> [CGPoint] {
      let inset = min(4, frame.width / 4)
      return [
        CGPoint(x: frame.maxX - inset, y: frame.midY),
        CGPoint(x: frame.maxX + 6, y: frame.midY),
      ]
    }
    switch section {
    case .visible:
      return dividers.hidden.map(rightPart) ?? []
    case .hidden:
      return dividers.hidden.map(leftPart) ?? []
    case .alwaysHidden:
      return dividers.alwaysHidden.map(leftPart) ?? []
    }
  }

  /// Groups items by section, each section ordered left to right.
  public static func sections(
    of items: [MenuBarItem], dividers: DividerFrames
  ) -> [MenuBarSection: [MenuBarItem]] {
    var result: [MenuBarSection: [MenuBarItem]] = [.visible: [], .hidden: [], .alwaysHidden: []]
    for item in items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
      result[section(of: item.frame, dividers: dividers), default: []].append(item)
    }
    return result
  }
}

/// Geometry of the display that hosts the menu bar, in window-server points.
public struct MenuBarGeometry: Equatable, Sendable {
  /// Horizontal span of the display, in window-server coordinates.
  public var span: ClosedRange<CGFloat>
  /// Horizontal span covered by the camera housing, if the display has one.
  public var notch: ClosedRange<CGFloat>?

  public init(span: ClosedRange<CGFloat>, notch: ClosedRange<CGFloat>?) {
    self.span = span
    self.notch = notch
  }

  public init(screenWidth: CGFloat, notch: ClosedRange<CGFloat>?) {
    self.init(span: 0...screenWidth, notch: notch)
  }

  /// Room macOS keeps clear right of the notch: an item starting within it
  /// isn't drawn either (measured on macOS 26: drawn at 30 pt, not at 16 pt).
  public static let notchClearance: CGFloat = 20

  /// Leftmost position at which an item is drawn.
  public var firstDrawnX: CGFloat {
    notch.map { $0.upperBound + Self.notchClearance } ?? span.lowerBound
  }

  /// Whether an item at `frame` is drawn and can be picked up: fully on the
  /// display and, on a display with a notch, clear of it. macOS doesn't draw
  /// status items behind the notch, just right of it, or to its left.
  public func isReachable(_ frame: CGRect) -> Bool {
    guard frame.minX >= span.lowerBound, frame.maxX <= span.upperBound else { return false }
    return frame.minX >= firstDrawnX
  }

  /// Whether the cursor can get to `point`; it can also go behind the notch.
  public func isReachable(_ point: CGPoint) -> Bool {
    span.contains(point.x)
  }
}

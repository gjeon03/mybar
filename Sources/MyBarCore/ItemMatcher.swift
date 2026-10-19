import CoreGraphics
import Foundation

/// Pairs status-item windows with the Accessibility elements that describe them.
///
/// Window frames include padding around the visible icon, so an AX element is
/// matched to the window whose horizontal span contains the element's center.
public enum ItemMatcher {
  /// `remembered` holds owners found earlier, by window ID. They are used for
  /// windows no element matches now: Accessibility reports meaningless
  /// positions for items that are off screen on some menu bars, while a
  /// status item keeps its window ID.
  public static func match(
    windows: [WindowInfo], axItems: [AXItemInfo], remembered: [CGWindowID: AXItemInfo] = [:]
  ) -> [MenuBarItem] {
    var unused = axItems
    var matched: [(WindowInfo, AXItemInfo?)] = []
    for window in windows.sorted(by: { $0.frame.minX < $1.frame.minX }) {
      let span = window.frame.minX - 1...window.frame.maxX + 1
      let candidates = unused.enumerated().filter { _, ax in
        ax.frame.width > 0 && span.contains(ax.frame.midX)
      }
      let best = candidates.min { lhs, rhs in
        abs(lhs.element.frame.midX - window.frame.midX) < abs(rhs.element.frame.midX - window.frame.midX)
      }
      if let best {
        matched.append((window, best.element))
        unused.remove(at: best.offset)
      } else {
        matched.append((window, remembered[window.windowID]))
      }
    }
    return assignKeys(matched)
  }

  /// Builds keys of the form `bundle/identifier`, disambiguating repeats with `#n`.
  static func assignKeys(_ pairs: [(WindowInfo, AXItemInfo?)]) -> [MenuBarItem] {
    var seen: [String: Int] = [:]
    return pairs.map { window, owner in
      let base = baseKey(window: window, owner: owner)
      let count = seen[base, default: 0]
      seen[base] = count + 1
      let key = count == 0 ? base : "\(base)#\(count)"
      return MenuBarItem(window: window, owner: owner, key: ItemKey(key))
    }
  }

  static func baseKey(window: WindowInfo, owner: AXItemInfo?) -> String {
    let app = owner?.bundleID ?? window.ownerName
    let detail =
      owner?.identifier?.nonEmpty
      ?? window.title.nonEmpty
      ?? owner?.label?.nonEmpty
      ?? "item"
    return "\(app)/\(detail)"
  }
}

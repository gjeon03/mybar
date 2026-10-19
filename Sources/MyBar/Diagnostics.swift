import AppKit
import MyBarCore

/// A plain-text report about the menu bar, for diagnosing MyBar on a Mac
/// the developer can't test on (a newer macOS, say). It lists only MyBar's
/// own state and windows near the top of each display that aren't ordinary
/// app windows, so no document or window contents are included.
@MainActor
enum Diagnostics {
  static func report(statusItems: StatusItems, snapshot: MenuBarSnapshot) -> String {
    var lines: [String] = []
    let info = Bundle.main.infoDictionary
    lines.append("MyBar \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
    lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    lines.append("Accessibility \(Permissions.accessibility), Screen Recording \(Permissions.screenRecording)")

    let mapping = MenuBarScanner.displayMapping()
    lines.append("\n## Displays (primary \(rect(mapping.primary)))")
    for screen in NSScreen.screens {
      let left = screen.auxiliaryTopLeftArea.map(rect) ?? "-"
      let right = screen.auxiliaryTopRightArea.map(rect) ?? "-"
      lines.append(
        "\(screen.localizedName): frame \(rect(screen.frame)) visible \(rect(screen.visibleFrame)) "
          + "safeTop \(screen.safeAreaInsets.top) notch areas \(left) \(right)")
    }

    lines.append("\n## MyBar's own items")
    for (name, item) in [
      ("control", statusItems.control), ("hidden", statusItems.hiddenDivider),
      ("alwaysHidden", statusItems.alwaysHiddenDivider),
    ] {
      let window = item.button?.window
      lines.append(
        "\(name): window \(window?.windowNumber ?? -1) frame \(window.map { rect($0.frame) } ?? "-") "
          + "level \(window?.level.rawValue ?? -1) length \(item.length)")
    }

    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let shape = MenuBarScanner.statusWindowShape(in: list, mapping: mapping)
    lines.append("\n## Status window shape: \(shape)")
    lines.append("statusWindows(): \(MenuBarScanner.statusWindows().count)")
    lines.append(
      "last scan: \(snapshot.items.count) items, control \(snapshot.controlItem.map { rect($0.frame) } ?? "-"), "
        + "hidden divider \(snapshot.dividers.hidden.map(rect) ?? "-"), "
        + "always hidden divider \(snapshot.dividers.alwaysHidden.map(rect) ?? "-")")

    lines.append("\n## Windows near the top of a display (not ordinary app windows)")
    var count = 0
    for window in list {
      guard let layer = window[kCGWindowLayer as String] as? Int, layer != 0,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds), frame.height < 120,
        let display = mapping.display(of: frame) ?? mapping.displays.first(where: { $0.intersects(frame) }),
        frame.minY - display.minY < 80
      else { continue }
      count += 1
      if count > 250 { break }
      let owner = window[kCGWindowOwnerName as String] as? String ?? ""
      let title = (window[kCGWindowName as String] as? String ?? "").prefix(40)
      let id = window[kCGWindowNumber as String] as? Int ?? 0
      let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
      lines.append("\(id) layer \(layer) \(rect(frame)) on \(onScreen) owner \(owner) title \(title)")
    }

    lines.append("\n## Accessibility menu bar extras")
    let extras = MenuBarScanner.accessibilityItems(thorough: true)
    lines.append("\(extras.count) elements")
    for item in extras.sorted(by: { $0.frame.minX < $1.frame.minX }).prefix(80) {
      lines.append("\(item.bundleID) \(rect(item.frame)) id \(item.identifier ?? "-")")
    }
    return lines.joined(separator: "\n")
  }

  private static func rect(_ r: CGRect) -> String {
    "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
  }
}

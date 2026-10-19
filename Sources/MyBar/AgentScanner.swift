import AppKit
import MyBarCore
import os

/// Which menu bar MyBar is working with.
enum MenuBarSystem {
  /// macOS 27 and later draw every status item in MenuBarAgent's windows
  /// (see `AgentLayout`); earlier versions give each item a window of its own.
  static let usesAgent: Bool = !NSRunningApplication.runningApplications(
    withBundleIdentifier: AgentScanner.agentBundleID
  ).isEmpty
}

/// Reads the MenuBarAgent menu bar through Accessibility alone: there are no
/// per-item windows to read. Items get stand-in `WindowInfo`s (with a stable
/// made-up window ID) so the rest of MyBar can treat them as before.
enum AgentScanner {
  static let agentBundleID = "com.apple.MenuBarAgent"

  /// Elements found by the last scan, by item key, for pressing items:
  /// folded items are reported on top of each other, so they can't be told
  /// apart by position.
  private static let elements = OSAllocatedUnfairLock<[ItemKey: UncheckedElement]>(initialState: [:])

  struct UncheckedElement: @unchecked Sendable {
    let element: AXUIElement
  }

  static func element(for key: ItemKey) -> AXUIElement? {
    elements.withLock { $0[key]?.element }
  }

  struct Result {
    var snapshot: MenuBarSnapshot
    /// The chevron that shows folded items, when anything is folded.
    var chevron: CGRect?
    /// MyBar's hidden divider, if shown.
    var spacer: CGRect?
  }

  /// Just the chevron's frame, asking MenuBarAgent alone (quick enough to
  /// poll), or nil when nothing is folded.
  static func chevron() -> CGRect? {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first else {
      return nil
    }
    let element = AXUIElementCreateApplication(agent.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.2)
    guard let bar: AXUIElement = AX.value(element, "AXExtrasMenuBar"),
      let children: [AXUIElement] = AX.value(bar, kAXChildrenAttribute)
    else { return nil }
    for child in children {
      let inner: [AXUIElement]? = AX.value(child, kAXChildrenAttribute)
      if inner?.isEmpty ?? true, let frame = AX.frame(of: child), frame.width > 0 { return frame }
    }
    return nil
  }

  static func scan() -> Result {
    var found: [(info: AXItemInfo, element: AXUIElement)] = []
    let controlCenterPID = NSRunningApplication.runningApplications(withBundleIdentifier: SystemModules.bundleID)
      .first?.processIdentifier
    var chevron: CGRect?
    for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.processIdentifier > 0 {
      let appElement = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(appElement, 0.25)
      guard let bar: AXUIElement = AX.value(appElement, "AXExtrasMenuBar"),
        let children: [AXUIElement] = AX.value(bar, kAXChildrenAttribute)
      else { continue }
      let bundleID = app.bundleIdentifier ?? app.localizedName ?? "pid-\(app.processIdentifier)"
      let name = app.localizedName ?? bundleID
      for child in children {
        guard let frame = AX.frame(of: child), frame.width > 0 else { continue }
        if bundleID == agentBundleID {
          // System items are groups hosting the real item; the chevron is
          // the one group without anything inside.
          guard let inner: [AXUIElement] = AX.value(child, kAXChildrenAttribute), let item = inner.first else {
            chevron = frame
            continue
          }
          // Its menus and panels are Control Center's.
          let info = AXItemInfo(
            bundleID: SystemModules.bundleID, pid: controlCenterPID ?? app.processIdentifier, appName: "Control Center",
            frame: frame,
            identifier: AX.value(item, kAXIdentifierAttribute), title: nil,
            label: AX.value(item, kAXDescriptionAttribute))
          found.append((info, item))
        } else {
          let info = AXItemInfo(
            bundleID: bundleID, pid: app.processIdentifier, appName: name, frame: frame,
            identifier: AX.value(child, kAXIdentifierAttribute), title: AX.value(child, kAXTitleAttribute),
            label: AX.value(child, kAXDescriptionAttribute))
          found.append((info, child))
        }
      }
    }

    var result = Result(snapshot: MenuBarSnapshot(), chevron: chevron, spacer: nil)
    let mapping = MenuBarScanner.displayMapping()
    result.snapshot.display =
      mapping.activeDisplay(of: found.map(\.info.frame))
    var table: [ItemKey: UncheckedElement] = [:]
    var seen: [String: Int] = [:]
    let ownPID = getpid()
    for (info, element) in found.sorted(by: { $0.info.frame.minX < $1.info.frame.minX }) {
      if info.pid == ownPID {
        let item = MenuBarItem(window: window(for: info, key: info.identifier ?? ""), owner: info, key: ItemKey(""))
        switch info.identifier {
        case OwnItemName.control?: result.snapshot.controlItem = item
        case OwnItemName.hidden?: result.spacer = info.frame
        case OwnItemName.alwaysHidden?: break
        case let name? where name.hasPrefix(OwnItemName.groupPrefix): result.snapshot.groupItems[name] = item
        default: break
        }
        continue
      }
      // Third-party items have no autosave name to read any more; most used
      // "Item-0", so keys stay the same as on earlier macOS versions.
      let detail = info.identifier?.nonEmpty ?? "Item-0"
      let base = "\(info.bundleID)/\(detail)"
      let count = seen[base, default: 0]
      seen[base] = count + 1
      let key = ItemKey(count == 0 ? base : "\(base)#\(count)")
      table[key] = UncheckedElement(element: element)
      result.snapshot.items.append(
        MenuBarItem(window: window(for: info, key: key.rawValue, chevron: chevron), owner: info, key: key))
    }
    let finished = table
    elements.withLock { $0 = finished }

    let concealed = Concealer.current.withLock { $0 }
    result.snapshot.concealed = concealed
    // A hidden Control Center item is gone from the menu bar altogether (an
    // app's concealed items are still reported, where they last were); list
    // it anyway, off screen, so it can be shown in MyBar's bar and opened.
    let present = Set(result.snapshot.items.map(\.key.rawValue))
    for raw in concealed.keys where !present.contains(raw) {
      let key = ItemKey(raw)
      guard let name = SystemModules.displayName(for: key) else { continue }
      let identifier = String(raw.dropFirst(SystemModules.bundleID.count + 1))
      let info = AXItemInfo(
        bundleID: SystemModules.bundleID, pid: 0, appName: "Control Center",
        frame: CGRect(x: -2000, y: 0, width: 30, height: 24),
        identifier: identifier, title: nil, label: name)
      result.snapshot.items.append(MenuBarItem(window: window(for: info, key: raw), owner: info, key: key))
    }
    return result
  }

  /// A stand-in window for an item: its frame, a window ID derived from the
  /// key, and whether it is drawn (not folded).
  private static func window(for info: AXItemInfo, key: String, chevron: CGRect? = nil) -> WindowInfo {
    WindowInfo(
      windowID: stableID(key), frame: info.frame, title: info.identifier ?? "", ownerPID: info.pid,
      ownerName: info.appName, isOnScreen: !AgentLayout.isFolded(info.frame, chevron: chevron))
  }

  /// FNV-1a: stable across launches, unlike `hashValue`.
  private static func stableID(_ key: String) -> CGWindowID {
    var hash: UInt32 = 2_166_136_261
    for byte in key.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    return hash | 0x8000_0000
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

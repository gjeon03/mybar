import AppKit
import ApplicationServices
import MyBarCore
import os

/// A point-in-time view of the menu bar.
struct MenuBarSnapshot {
  /// Bounds of the display whose menu bar holds the real status-item windows
  /// (the active one); other displays show copies.
  var display: CGRect = CGDisplayBounds(CGMainDisplayID())
  /// Items that belong to other applications and the system.
  var items: [MenuBarItem] = []
  var dividers = DividerFrames(hidden: nil, alwaysHidden: nil)
  var controlItem: MenuBarItem?
  /// MyBar's group items keyed by autosave name.
  var groupItems: [String: MenuBarItem] = [:]
  /// On macOS 27+, sections come from the concealed apps (see `Concealer`)
  /// instead of from positions relative to dividers.
  var concealed: [String: MenuBarSection]?

  var sections: [MenuBarSection: [MenuBarItem]] {
    guard concealed != nil else { return MenuBarLayout.sections(of: items, dividers: dividers) }
    var result: [MenuBarSection: [MenuBarItem]] = [.visible: [], .hidden: [], .alwaysHidden: []]
    for item in items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
      result[section(of: item), default: []].append(item)
    }
    return result
  }

  func item(for key: ItemKey) -> MenuBarItem? {
    items.first { $0.key == key }
  }

  func section(of item: MenuBarItem) -> MenuBarSection {
    if let concealed { return Concealment.section(of: item.key, concealed: concealed) }
    return MenuBarLayout.section(of: item.frame, dividers: dividers)
  }

  /// This snapshot with frames re-read from the window server. Identities
  /// come from the original scan; window IDs don't change when items move.
  func withCurrentFrames() -> MenuBarSnapshot {
    // Without item windows there is nothing cheaper than a scan.
    if MenuBarSystem.usesAgent { return AgentScanner.scan().snapshot }
    let windows = MenuBarScanner.statusWindows()
    let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    func updated(_ item: MenuBarItem) -> MenuBarItem {
      byID[item.window.windowID].map { MenuBarItem(window: $0, owner: item.owner, key: item.key) } ?? item
    }
    var copy = self
    copy.items = items.map(updated)
    copy.controlItem = controlItem.map(updated)
    copy.groupItems = groupItems.mapValues(updated)
    let mapping = MenuBarScanner.displayMapping()
    let own = windows.filter { mapping.display(of: $0.frame) == display }
    copy.dividers.hidden = own.first { $0.title == OwnItemName.hidden }?.frame ?? dividers.hidden
    copy.dividers.alwaysHidden = own.first { $0.title == OwnItemName.alwaysHidden }?.frame ?? dividers.alwaysHidden
    return copy
  }
}

/// Reads status-item windows from the window server and labels them with
/// their owning applications via Accessibility.
enum MenuBarScanner {
  static func scan(thorough: Bool = false) -> MenuBarSnapshot {
    if MenuBarSystem.usesAgent { return AgentScanner.scan().snapshot }
    var watch = Stopwatch("scan")
    defer { watch.lap("done") }
    let mapping = displayMapping()
    let all = statusWindows()
    watch.lap("windows")
    let display = activeDisplay(windows: all, mapping: mapping)
    let windows = all.filter { mapping.display(of: $0.frame) == display }
    // Accessibility reports frames on the menu bar it considers active, which
    // can briefly differ from where the windows are; align the two.
    let reported = accessibilityItems(thorough: thorough)
    watch.lap("accessibility")
    let source = mapping.activeDisplay(of: reported.map(\.frame))
    let axItems = reported.map { $0.with(frame: mapping.convert($0.frame, from: source, to: display)) }
    let matched = ItemMatcher.match(
      windows: windows, axItems: axItems, remembered: OwnerMemory.shared.owners(of: all.map(\.windowID)))
    OwnerMemory.shared.remember(matched)
    let ownPID = getpid()

    var snapshot = MenuBarSnapshot()
    snapshot.display = display
    for item in matched {
      let name = ownName(of: item, ownPID: ownPID)
      switch name {
      case OwnItemName.control?:
        snapshot.controlItem = item
      case OwnItemName.hidden?:
        snapshot.dividers.hidden = item.frame
      case OwnItemName.alwaysHidden?:
        snapshot.dividers.alwaysHidden = item.frame
      case let name? where name.hasPrefix(OwnItemName.groupPrefix):
        snapshot.groupItems[name] = item
      case .some:
        continue
      case nil:
        snapshot.items.append(item)
      }
    }
    Log.scan.debug(
      "scan: \(snapshot.items.count) items, hidden divider \(String(describing: snapshot.dividers.hidden))")
    return snapshot
  }

  /// MyBar's own items are recognized by the Accessibility identifier MyBar
  /// sets on its buttons. Window titles are autosave names that any app can
  /// choose, so a title is trusted only when no owner could be matched (for
  /// example a collapsed divider far off screen), never over another app's
  /// Accessibility element.
  private static func ownName(of item: MenuBarItem, ownPID: pid_t) -> String? {
    if let owner = item.owner {
      guard owner.pid == ownPID else { return nil }
      return owner.identifier ?? (item.window.title.isEmpty ? "MyBarUnknown" : item.window.title)
    }
    return item.window.title.hasPrefix(OwnItemName.prefix) ? item.window.title : nil
  }

  // MARK: - Window server

  static func displayMapping() -> DisplayMapping {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return DisplayMapping(
      primary: CGDisplayBounds(CGMainDisplayID()), displays: ids.prefix(Int(count)).map(CGDisplayBounds))
  }

  /// The display whose menu bar holds the real status-item windows. macOS
  /// moves them to the menu bar the user is working in and leaves copies,
  /// titled differently, on the other displays; MyBar's own control window
  /// keeps its autosave name only where it is real.
  static func activeDisplay(windows: [WindowInfo], mapping: DisplayMapping) -> CGRect {
    windows.first { $0.title == OwnItemName.control }.flatMap { mapping.display(of: $0.frame) } ?? mapping.primary
  }

  /// How status-item windows look: learned from the window of MyBar's own
  /// icon (found by its title, whatever its level or size), which looks like
  /// every other status item on this version of macOS. Falls back to the
  /// values measured on macOS 26.
  struct StatusWindowShape: Equatable {
    var level = Int(CGWindowLevelForKey(.statusWindow))
    var maximumHeight: CGFloat = 50
    var topOffset: CGFloat = 0
  }

  static func statusWindowShape(in list: [[String: Any]], mapping: DisplayMapping) -> StatusWindowShape {
    var shape = StatusWindowShape()
    guard
      let window = list.first(where: {
        ($0[kCGWindowName as String] as? String) == OwnItemName.control
          && ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid()
      }) ?? list.first(where: { ($0[kCGWindowName as String] as? String) == OwnItemName.control }),
      let layer = window[kCGWindowLayer as String] as? Int,
      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
      let frame = CGRect(dictionaryRepresentation: bounds), frame.height > 0,
      let display = mapping.display(of: frame)
    else { return shape }
    shape.level = layer
    shape.maximumHeight = max(50, frame.height * 1.5)
    shape.topOffset = frame.minY - display.minY
    return shape
  }

  /// Status-item windows in the menu bar of any display, real or copies.
  static func statusWindows() -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
      return []
    }
    let mapping = displayMapping()
    let shape = statusWindowShape(in: list, mapping: mapping)
    return list.compactMap { window in
      guard (window[kCGWindowLayer as String] as? Int) == shape.level,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds),
        frame.width > 0, frame.height > 0, frame.height <= shape.maximumHeight,
        let display = mapping.display(of: frame), abs(frame.minY - display.minY - shape.topOffset) < 4,
        let id = window[kCGWindowNumber as String] as? CGWindowID
      else { return nil }
      return WindowInfo(
        windowID: id,
        frame: frame,
        title: window[kCGWindowName as String] as? String ?? "",
        ownerPID: window[kCGWindowOwnerPID as String] as? pid_t ?? 0,
        ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
        isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
  }

  // MARK: - Accessibility

  private struct AppRef {
    let pid: pid_t
    let bundleID: String
    let name: String
  }

  /// Reads every app's menu bar extras through Accessibility. Asking each
  /// running app is slow (some answer only at the timeout), so apps known to
  /// have no extras are skipped unless `thorough` is set; a thorough pass runs
  /// in the background now and then to notice apps that add an item later.
  static func accessibilityItems(thorough: Bool = false) -> [AXItemInfo] {
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppRef? in
      guard !app.isTerminated, app.processIdentifier > 0 else { return nil }
      return AppRef(
        pid: app.processIdentifier,
        bundleID: app.bundleIdentifier ?? app.localizedName ?? "pid-\(app.processIdentifier)",
        name: app.localizedName ?? app.bundleIdentifier ?? "Unknown")
    }
    let toAsk = thorough ? apps : apps.filter { !ExtrasCache.shared.knownWithout($0.pid) }
    let lock = NSLock()
    var result: [AXItemInfo] = []
    DispatchQueue.concurrentPerform(iterations: toAsk.count) { index in
      let app = toAsk[index]
      let infos = extrasItems(of: app)
      ExtrasCache.shared.record(app.pid, hasExtras: !infos.isEmpty)
      guard !infos.isEmpty else { return }
      lock.lock()
      result.append(contentsOf: infos)
      lock.unlock()
    }
    ExtrasCache.shared.forget(except: Set(apps.map(\.pid)))
    return result
  }

  /// Owners of status-item windows as last matched, by window ID. Saved, as
  /// window IDs outlive MyBar: it may start while the owners can't be read.
  private final class OwnerMemory: @unchecked Sendable {
    static let shared = OwnerMemory()
    private static let defaultsKey = "MyBarKnownOwners"
    private let lock = NSLock()
    private var owners: [CGWindowID: AXItemInfo] = {
      guard let data = UserDefaults.standard.data(forKey: defaultsKey),
        let saved = try? JSONDecoder().decode([CGWindowID: AXItemInfo].self, from: data)
      else { return [:] }
      return saved
    }()

    /// The remembered owners of `windowIDs`; the others are forgotten.
    func owners(of windowIDs: [CGWindowID]) -> [CGWindowID: AXItemInfo] {
      lock.lock()
      defer { lock.unlock() }
      let current = Set(windowIDs)
      owners = owners.filter { current.contains($0.key) }
      return owners
    }

    func remember(_ items: [MenuBarItem]) {
      lock.lock()
      defer { lock.unlock() }
      var changed = false
      for item in items {
        guard let owner = item.owner, owners[item.window.windowID] != owner else { continue }
        owners[item.window.windowID] = owner
        changed = true
      }
      if changed, let data = try? JSONEncoder().encode(owners) {
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
      }
    }
  }

  /// Which processes were found to have no menu bar extras.
  private final class ExtrasCache: @unchecked Sendable {
    static let shared = ExtrasCache()
    private let lock = NSLock()
    private var without: Set<pid_t> = []

    func knownWithout(_ pid: pid_t) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return without.contains(pid)
    }

    func record(_ pid: pid_t, hasExtras: Bool) {
      lock.lock()
      defer { lock.unlock() }
      if hasExtras { without.remove(pid) } else { without.insert(pid) }
    }

    /// Drops processes that are gone; their IDs may be reused.
    func forget(except running: Set<pid_t>) {
      lock.lock()
      defer { lock.unlock() }
      without.formIntersection(running)
    }
  }

  private static func extrasItems(of app: AppRef) -> [AXItemInfo] {
    let appElement = AXUIElementCreateApplication(app.pid)
    AXUIElementSetMessagingTimeout(appElement, 0.25)
    guard let bar: AXUIElement = AX.value(appElement, "AXExtrasMenuBar"),
      let children: [AXUIElement] = AX.value(bar, kAXChildrenAttribute)
    else { return [] }
    return children.compactMap { child in
      guard let frame = AX.frame(of: child), frame.width > 0 else { return nil }
      return AXItemInfo(
        bundleID: app.bundleID,
        pid: app.pid,
        appName: app.name,
        frame: frame,
        identifier: AX.value(child, kAXIdentifierAttribute),
        title: AX.value(child, kAXTitleAttribute),
        label: AX.value(child, kAXDescriptionAttribute))
    }
  }

  /// Finds the live Accessibility element for `item`, for pressing it.
  static func element(for item: MenuBarItem) -> AXUIElement? {
    if MenuBarSystem.usesAgent { return AgentScanner.element(for: item.key) }
    guard let pid = item.owner?.pid else { return nil }
    let appElement = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(appElement, 0.5)
    guard let bar: AXUIElement = AX.value(appElement, "AXExtrasMenuBar"),
      let children: [AXUIElement] = AX.value(bar, kAXChildrenAttribute)
    else { return nil }
    let frames = children.map { AX.frame(of: $0) }
    let mapping = displayMapping()
    let source = mapping.activeDisplay(of: frames.compactMap { $0 })
    let destination = mapping.display(of: item.frame) ?? mapping.primary
    let span = item.frame.minX - 1...item.frame.maxX + 1
    return zip(children, frames).first { _, frame in
      guard let frame else { return false }
      return span.contains(mapping.convert(frame, from: source, to: destination).midX)
    }?.0
  }
}

enum AX {
  static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
  }

  static func frame(of element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
      let positionRef, let sizeRef
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    // swiftlint:disable force_cast
    AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    // swiftlint:enable force_cast
    return CGRect(origin: position, size: size)
  }

  static func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
  }
}

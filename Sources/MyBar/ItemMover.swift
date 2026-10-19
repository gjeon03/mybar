import AppKit
import MyBarCore

/// Rearranges menu bar items by command-dragging them across MyBar's dividers.
///
/// Every section is expanded while moving so that both the item and the drop
/// target are on screen. Each drag is verified with a fresh scan and retried
/// with an alternative drop point, because the menu bar decides the final
/// slot from the cursor position relative to the items around it.
@MainActor
final class ItemMover {
  enum MoveError: LocalizedError, Equatable {
    case notFound
    case unmovable(String)
    case notReachable(String)
    case missingDivider
    case missingPermission
    case noRoom(String)
    case verificationFailed(String)

    var errorDescription: String? {
      switch self {
      case .notFound: "The item is no longer in the menu bar."
      case .unmovable(let name): "\(name) is fixed in place by macOS."
      case .notReachable(let name):
        "\(name) can't be reached: even with every section expanded it sits behind the notch or off screen, "
          + "where macOS doesn't let it be dragged. Open it from the MyBar Bar instead, or move it while you "
          + "work on a display without a notch."
      case .missingDivider: "MyBar's divider is not in the menu bar yet. Try again in a moment."
      case .missingPermission: "MyBar needs Accessibility and Screen Recording permission to move items."
      case .noRoom(let name):
        "There's no room in the menu bar to show \(name). Hide another item first, then try again."
      case .verificationFailed(let name): "Could not move \(name). Try again or drag it with ⌘ held."
      }
    }
  }

  private static let editSource = "edit"
  private let statusItems: StatusItems
  private let curtain: MenuBarCurtain
  private let shield: InputShield
  private let standIn: CursorStandIn

  init(statusItems: StatusItems, curtain: MenuBarCurtain, shield: InputShield, standIn: CursorStandIn) {
    self.statusItems = statusItems
    self.curtain = curtain
    self.shield = shield
    self.standIn = standIn
  }

  /// Conceals items on the MenuBarAgent menu bar (macOS 27+), where moving
  /// an item between sections just changes what is concealed.
  var concealer: Concealer?
  /// Pictures an item that is about to be concealed, while it is still drawn.
  var pictureBeforeConcealing: ((ItemKey) async -> Void)?

  /// Moves each item to `section`. Returns the errors of the items that failed.
  /// `known` is a recent scan to identify items by; without one MyBar scans
  /// while it covers the menu bar.
  func move(_ keys: [ItemKey], to section: MenuBarSection, known: MenuBarSnapshot? = nil) async -> [ItemKey: Error] {
    await perform(keys.map { ($0, section) }, known: known)
  }

  /// Makes several moves, in order, in one editing session (one cover, one
  /// expansion), which is quicker and calmer than separate moves.
  /// `allowOtherDisplay` lets MyBar switch to another display's menu bar
  /// for items it can't reach; worth it for a rearrangement the person asked
  /// for, too surprising for simply opening an item.
  func perform(
    _ moves: [(ItemKey, MenuBarSection)], known: MenuBarSnapshot? = nil, allowOtherDisplay: Bool = true
  ) async -> [ItemKey: Error] {
    guard !moves.isEmpty else { return [:] }
    // Without these, dividers can't be found and the cover can't be pictured:
    // the menu bar would visibly expand and nothing would move.
    guard Permissions.accessibility, Permissions.screenRecording else {
      return Dictionary(uniqueKeysWithValues: moves.map { ($0.0, MoveError.missingPermission as Error) })
    }
    if MenuBarSystem.usesAgent, let concealer {
      var failures: [ItemKey: Error] = [:]
      for (key, section) in moves {
        // Control Center's items are hidden one by one, and the clock and
        // Control Center itself not at all.
        if SystemModules.isSystemItem(key), SystemModules.preferenceKey(for: key) == nil {
          failures[key] = MoveError.unmovable(key.rawValue)
          continue
        }
        if section != .visible, concealer.section(of: key) == .visible {
          await pictureBeforeConcealing?(key)
        }
        await concealer.assign(key, to: section)
      }
      return failures
    }
    var watch = Stopwatch("move")
    // Identify items once, while the menu bar is still; during the move only
    // positions change, and those come from the window server.
    let scanning = known == nil ? Task.detached(priority: .userInitiated) { MenuBarScanner.scan() } : nil
    await cover()
    let base: MenuBarSnapshot
    if let known {
      base = known
    } else if let scanning {
      base = await scanning.value
    } else {
      base = await MenuBarScanner.scanAsync()
    }
    // Keep the always-hidden divider collapsed unless that section is part
    // of the move. Collapsed, it reaches far off screen, so an item dropped
    // next to it can't slip past it into Always Hidden.
    let touchesAlwaysHidden = moves.contains { key, section in
      section == .alwaysHidden || base.item(for: key).map { base.section(of: $0) == .alwaysHidden } == true
    }
    await expand(touchesAlwaysHidden ? .all : .hidden)
    watch.lap("begin editing")
    defer { watch.lap("end editing") }
    var failures: [ItemKey: Error] = [:]
    displaced = [:]
    for (key, section) in moves {
      do {
        try await move(
          matching: { $0.item(for: key) }, to: section, base: base, allowOtherDisplay: allowOtherDisplay)
        watch.lap("moved one")
      } catch {
        Log.move.error("move \(key.rawValue) failed: \(error.localizedDescription)")
        failures[key] = error
      }
    }
    // Moving a divider past an item takes its neighbors along; put them back.
    let requested = Set(moves.map(\.0))
    for (key, section) in displaced where !requested.contains(key) {
      do {
        try await move(matching: { $0.item(for: key) }, to: section, base: await MenuBarScanner.scanAsync())
      } catch {
        Log.move.error("could not put \(key.rawValue) back in \(section.rawValue): \(error.localizedDescription)")
      }
    }
    displaced = [:]
    await endEditing()
    return failures
  }

  /// Moves one of MyBar's own group items into the visible section.
  func placeGroupItem(named autosaveName: String) async throws {
    // Nothing to move: MyBar's own items are never concealed.
    if MenuBarSystem.usesAgent { return }
    let base = await MenuBarScanner.scanAsync()
    await cover()
    await expand(.hidden)
    do {
      try await move(matching: { $0.groupItems[autosaveName] }, to: .visible, base: base)
    } catch {
      await endEditing()
      throw error
    }
    await endEditing()
  }

  /// Covers the menu bars, keeps the pointer looking still and holds the
  /// person's clicks back, so the rearranging is neither seen nor disturbed.
  private func cover() async {
    shield.raise()
    await standIn.raise()
    await curtain.raise()
  }

  /// Expands the sections a move needs.
  private func expand(_ level: RevealLevel) async {
    statusItems.setLevel(level, for: Self.editSource)
    // Wait for the dividers to shrink rather than a fixed time.
    for _ in 0..<40 {
      await sleep(milliseconds: 12)
      let divider = MenuBarScanner.statusWindows().first { $0.title == OwnItemName.hidden }
      if let divider, divider.frame.width < StatusItems.collapsedLength / 10 { break }
    }
    await sleep(milliseconds: 25)
  }

  private func endEditing() async {
    statusItems.setLevel(.none, for: Self.editSource)
    // Someone else keeps the menu bar covered (an item being opened); they
    // wait for the collapse before lifting it, so don't wait here.
    if !curtain.isHeldByOthers { await waitForCollapse() }
    curtain.lower()
    standIn.lower()
    shield.lower()
  }

  /// Waits until the menu bar has collapsed again after editing.
  func waitForCollapse() async {
    for _ in 0..<35 {
      await sleep(milliseconds: 12)
      let divider = MenuBarScanner.statusWindows().first { $0.title == OwnItemName.hidden }
      if statusItems.effectiveLevel != .none || (divider?.frame.width ?? 0) > StatusItems.collapsedLength / 10 { break }
    }
    await sleep(milliseconds: 25)
  }

  private func move(
    matching find: (MenuBarSnapshot) -> MenuBarItem?, to section: MenuBarSection, base: MenuBarSnapshot,
    allowOtherDisplay: Bool = true
  ) async throws {
    let maxAttempts = 3
    var triedOtherDisplay = !allowOtherDisplay || Self.singleDisplayForTesting
    var triedDivider = false
    var attempt = 0
    var base = base
    while true {
      var snapshot = base.withCurrentFrames()
      var found = find(snapshot)
      if found == nil
        || snapshot.display
          != MenuBarScanner.activeDisplay(
            windows: MenuBarScanner.statusWindows(), mapping: MenuBarScanner.displayMapping())
      {
        // The item is new to us, or another display's menu bar became active
        // (its windows replace the ones we knew): identify everything again.
        base = await MenuBarScanner.scanAsync()
        snapshot = base
        found = find(snapshot)
      }
      guard let item = found else { throw MoveError.notFound }
      if snapshot.section(of: item) == section { return }
      if attempt == maxAttempts { throw MoveError.verificationFailed(item.displayName) }
      if Self.isFixed(item) { throw MoveError.unmovable(item.displayName) }
      guard item.window.isOnScreen, Self.isReachable(item.frame) else {
        if await bringIntoReach(item.key, in: snapshot) { continue }
        // Nothing drawn to slide it with: move the divider past it instead.
        if !triedDivider, await moveDivider(past: item, toward: section, in: snapshot) {
          triedDivider = true
          base = await MenuBarScanner.scanAsync()
          continue
        }
        // A display without a notch has room for every item. Its menu bar
        // holds the real windows only while it is active, so activate it.
        if !triedOtherDisplay, await activateRoomierMenuBar(than: snapshot.display) {
          triedOtherDisplay = true
          continue
        }
        throw MoveError.notReachable(item.displayName)
      }
      defer { attempt += 1 }
      let geometry = Self.geometry(of: snapshot.display)
      let points = MenuBarLayout.dropPoints(into: section, dividers: snapshot.dividers).filter {
        geometry.isReachable($0)
      }
      guard !points.isEmpty else { throw MoveError.missingDivider }
      let target = points[attempt % points.count]
      Log.move.info("drag \(item.key.rawValue) from \(item.frame.midX) to \(target.x) for \(section.rawValue)")
      // Swift first; if the menu bar didn't take it, retry at calmer paces.
      var watch = Stopwatch("drag")
      await EventDriver.commandDragAsync(
        from: CGPoint(x: item.frame.midX, y: item.frame.midY), to: target,
        pace: attempt == 0 ? .swift : attempt == 1 ? .quick : .standard)
      watch.lap("dragged")
      // Verify from the window server alone; a full scan is only needed when
      // the item didn't land where it should.
      let after = await Self.settle(snapshot, watching: [item.window.windowID])
      watch.lap("settled")
      let landed = (after.items + Array(after.groupItems.values)).first { $0.window.windowID == item.window.windowID }
      if let landed, after.section(of: landed) == section { return }
    }
  }

  /// Slides the item with `key` right until it can be dragged, by dropping
  /// drawn items of the same section just left of it (see `ReachPlanner`).
  /// Returns whether it became reachable.
  private func bringIntoReach(_ key: ItemKey, in start: MenuBarSnapshot) async -> Bool {
    var snapshot = start
    let geometry = Self.geometry(of: snapshot.display)
    // Sliding must never take long: it holds the person's clicks back and
    // keeps the menu bar covered.
    let deadline = Date().addingTimeInterval(Self.slideBudget)
    var stalled = 0
    // Items the menu bar wouldn't let go of (one that was just moved, for
    // example); others are tried instead.
    var refused: Set<ItemKey> = []
    while Date() < deadline {
      guard let target = snapshot.item(for: key) else { return false }
      if geometry.isReachable(target.frame) {
        if target.window.isOnScreen { return true }
        // Where it is, it can be dragged once macOS draws it, which takes a
        // moment after the sections expand.
        return await Self.waitUntilDrawn(target.window.windowID, in: snapshot)
      }
      let section = snapshot.section(of: target)
      let candidates = snapshot.items.filter { item in
        item.key != key && !refused.contains(item.key) && item.window.isOnScreen && !Self.isFixed(item)
          && snapshot.section(of: item) == section
      }
      guard
        let index = ReachPlanner.itemToShift(
          leftOf: target.frame, candidates: candidates.map(\.frame), geometry: geometry),
        let drop = ReachPlanner.dropPoint(
          leftOf: target.frame, carrying: candidates[index].frame.width, geometry: geometry)
      else {
        Log.move.info("nothing left to slide \(key.rawValue) into reach")
        return false
      }
      let mover = candidates[index]
      Log.move.info(
        """
        sliding \(key.rawValue, privacy: .public) [\(Int(target.frame.minX))+\(Int(target.frame.width))]: \
        drop \(mover.key.rawValue, privacy: .public) [\(Int(mover.frame.minX))+\(Int(mover.frame.width))] \
        at \(Int(drop.x)); always-hidden divider \(String(describing: snapshot.dividers.alwaysHidden), privacy: .public)
        """)
      // A drag that didn't take is retried at a calmer pace.
      await EventDriver.commandDragAsync(
        from: CGPoint(x: mover.frame.midX, y: mover.frame.midY), to: drop, pace: stalled == 0 ? .slide : .quick)
      snapshot = await Self.settle(snapshot, watching: [mover.window.windowID, target.window.windowID])
      let progressed = (snapshot.item(for: key)?.frame.minX ?? target.frame.minX) > target.frame.minX + 1
      if progressed {
        stalled = 0
      } else {
        refused.insert(mover.key)
        stalled += 1
        if stalled >= 3 {
          Log.move.error("sliding \(key.rawValue) made no progress; giving up")
          return false
        }
      }
      // Sliding must never change an item's section; undo it if it did.
      if let moved = snapshot.item(for: mover.key), snapshot.section(of: moved) != section {
        Log.move.error("sliding moved \(mover.key.rawValue) out of \(section.rawValue); putting it back")
        try? await move(matching: { $0.item(for: mover.key) }, to: section, base: snapshot, allowOtherDisplay: false)
        return false
      }
    }
    Log.move.error("sliding \(key.rawValue) ran out of time")
    return false
  }

  /// Waits briefly for the window with `windowID` to be drawn.
  private static func waitUntilDrawn(_ windowID: CGWindowID, in snapshot: MenuBarSnapshot) async -> Bool {
    for _ in 0..<30 {
      await sleep(milliseconds: 15)
      let current = snapshot.withCurrentFrames().items.first { $0.window.windowID == windowID }
      if current?.window.isOnScreen == true { return true }
    }
    Log.move.error("item \(windowID) was not drawn in time")
    return false
  }

  /// Items whose section changed only because a divider was moved past them,
  /// with the section to return them to.
  private var displaced: [ItemKey: MenuBarSection] = [:]

  /// Moves the divider between `item`'s section and the next one toward
  /// `section` to just past the item, so the item changes section without
  /// being picked up (see `StatusItems.relocateDivider`). Same-section items
  /// between the divider and the item change section too; they are recorded
  /// in `displaced`. Returns whether the item changed section.
  private func moveDivider(past item: MenuBarItem, toward section: MenuBarSection, in snapshot: MenuBarSnapshot) async
    -> Bool
  {
    let order: [MenuBarSection] = [.alwaysHidden, .hidden, .visible]
    let current = snapshot.section(of: item)
    guard let from = order.firstIndex(of: current), let to = order.firstIndex(of: section), from != to,
      item.frame.width > 4
    else { return false }
    let movingRight = to > from
    // The divider on the side the item leaves through.
    let divider =
      movingRight
      ? (current == .alwaysHidden ? OwnItemName.alwaysHidden : OwnItemName.hidden)
      : (current == .visible ? OwnItemName.hidden : OwnItemName.alwaysHidden)
    // Saved positions are distances from the display's right edge to an
    // item's right edge; a divider just left of the item sits between the
    // item and its left neighbor, one just right of it between the item and
    // its right neighbor.
    let right = snapshot.display.maxX
    let position = Int((right - (movingRight ? item.frame.minX : item.frame.maxX)).rounded()) - 2
    Log.move.info("moving \(divider) past \(item.key.rawValue) (position \(position))")
    statusItems.relocateDivider(divider, toPosition: position)
    await sleep(milliseconds: 150)
    let after = await MenuBarScanner.scanAsync()
    guard let moved = after.item(for: item.key), after.section(of: moved) != current else {
      Log.move.error("moving \(divider) didn't change \(item.key.rawValue)'s section")
      return false
    }
    for other in snapshot.items where other.key != item.key {
      let was = snapshot.section(of: other)
      if let now = after.item(for: other.key), after.section(of: now) != was, displaced[other.key] == nil {
        displaced[other.key] = was
      }
    }
    return true
  }

  /// Longest time spent sliding one item into reach.
  private static let slideBudget: TimeInterval = 3.5

  /// Waits for the windows in `windowIDs` to move after a drag (the dragged
  /// item, and when sliding also the item it should push along), then returns
  /// `snapshot` with every frame updated from the window server. Much faster
  /// than a full scan because it skips Accessibility.
  private static func settle(_ snapshot: MenuBarSnapshot, watching windowIDs: [CGWindowID]) async -> MenuBarSnapshot {
    func frames(_ snapshot: MenuBarSnapshot) -> [CGRect?] {
      let all = snapshot.items + Array(snapshot.groupItems.values)
      return windowIDs.map { id in all.first { $0.window.windowID == id }?.frame }
    }
    let before = frames(snapshot)
    // A drag the menu bar takes moves the item within a few milliseconds.
    for _ in 0..<14 {
      await sleep(milliseconds: 15)
      let now = frames(snapshot.withCurrentFrames())
      if zip(before, now).allSatisfy({ $0 != $1 }) { break }
    }
    // Neighbours finish shifting just after the dragged item lands.
    await sleep(milliseconds: 25)
    return snapshot.withCurrentFrames()
  }

  /// Makes the menu bar of another display without a notch the active one by
  /// clicking an empty part of it. Returns whether the menu bar switched.
  private func activateRoomierMenuBar(than current: CGRect) async -> Bool {
    let mapping = MenuBarScanner.displayMapping()
    let windows = MenuBarScanner.statusWindows()
    for display in mapping.displays where display != current && Self.geometry(of: display).notch == nil {
      guard let point = Self.emptyMenuBarPoint(on: display, windows: windows, mapping: mapping) else { continue }
      Log.move.info("activating the menu bar at \(point.x), \(point.y)")
      EventDriver.click(at: point)
      for _ in 0..<12 {
        await sleep(milliseconds: 100)
        if MenuBarScanner.activeDisplay(windows: MenuBarScanner.statusWindows(), mapping: mapping) == display {
          await sleep(milliseconds: 250)
          return true
        }
      }
    }
    return false
  }

  /// A point in the menu bar of `display` between the app menus and the
  /// leftmost status item, where a click does nothing but select that menu bar.
  private static func emptyMenuBarPoint(on display: CGRect, windows: [WindowInfo], mapping: DisplayMapping) -> CGPoint?
  {
    let leftmostItem =
      windows.filter { mapping.display(of: $0.frame) == display && $0.frame.minX >= display.minX }
      .map(\.frame.minX).min() ?? display.maxX
    let menusEnd = appMenusEnd(on: display, mapping: mapping) ?? display.minX + display.width / 2
    let start = menusEnd + 24
    let end = leftmostItem - 24
    guard end - start >= 16 else { return nil }
    return CGPoint(x: (start + end) / 2, y: display.minY + 10)
  }

  /// Right edge of the frontmost app's menus, moved onto `display`. App menus
  /// start at the left edge of whichever menu bar Accessibility reports.
  private static func appMenusEnd(on display: CGRect, mapping: DisplayMapping) -> CGFloat? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.25)
    guard let bar: AXUIElement = AX.value(element, kAXMenuBarAttribute),
      let children: [AXUIElement] = AX.value(bar, kAXChildrenAttribute)
    else { return nil }
    let frames = children.compactMap { AX.frame(of: $0) }.filter { $0.width > 0 }
    guard let last = frames.max(by: { $0.maxX < $1.maxX }), let source = mapping.display(of: last) else { return nil }
    return last.maxX - source.minX + display.minX
  }

  /// Debug builds can act as if no other display were connected
  /// (`MYBAR_SINGLE_DISPLAY=1`), to test what a laptop on its own does.
  private static let singleDisplayForTesting: Bool = {
    #if DEBUG
      ProcessInfo.processInfo.environment["MYBAR_SINGLE_DISPLAY"] == "1"
    #else
      false
    #endif
  }()

  /// Items macOS does not let anyone rearrange.
  static func isFixed(_ item: MenuBarItem) -> Bool {
    if MenuBarSystem.usesAgent, SystemModules.isSystemItem(item.key) {
      return SystemModules.preferenceKey(for: item.key) == nil
    }
    let key = item.key.rawValue
    return key.hasSuffix("/com.apple.menuextra.clock") || key.hasSuffix("/com.apple.menuextra.controlcenter")
  }

  /// Geometry of the display whose menu bar contains `frame` (window-server
  /// coordinates), falling back to the main display.
  static func geometry(at frame: CGRect) -> MenuBarGeometry {
    let mapping = MenuBarScanner.displayMapping()
    return geometry(of: mapping.display(of: frame) ?? mapping.primary)
  }

  /// Geometry of the display with window-server bounds `display`.
  static func geometry(of display: CGRect) -> MenuBarGeometry {
    let span = display.minX...display.maxX
    guard let screen = NSScreen.screen(withBounds: display) else { return MenuBarGeometry(span: span, notch: nil) }
    var notch: ClosedRange<CGFloat>?
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, left.maxX < right.minX {
      // The areas are in screen coordinates; shift them if they are relative to the screen.
      let offset = left.minX < screen.frame.minX ? screen.frame.minX : 0
      notch = (left.maxX + offset)...(right.minX + offset)
    }
    return MenuBarGeometry(span: span, notch: notch)
  }

  /// Whether a window-server rect is on its display and clear of the notch.
  static func isReachable(_ frame: CGRect) -> Bool {
    geometry(at: frame).isReachable(frame)
  }
}

extension NSScreen {
  /// The screen whose window-server bounds are `bounds`.
  static func screen(withBounds bounds: CGRect) -> NSScreen? {
    screens.first { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
      else { return false }
      return CGDisplayBounds(number) == bounds
    }
  }
}

extension MenuBarScanner {
  static func scanAsync(thorough: Bool = false) async -> MenuBarSnapshot {
    await Task.detached(priority: .userInitiated) { scan(thorough: thorough) }.value
  }
}

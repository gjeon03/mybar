import AppKit
import MyBarCore

/// Opens a hidden item as if it had been clicked in the menu bar.
///
/// The item alone is moved next to MyBar's icon (into the Visible section),
/// clicked there, and moved back to its section once its menu has closed.
/// If it can't be moved, the item is pressed through Accessibility where it is.
@MainActor
final class ItemActivator {
  private static let source = "activation"
  private static let pendingKey = "MyBarTemporarilyShown"
  private let statusItems: StatusItems
  private let mover: ItemMover
  private let curtain: MenuBarCurtain
  private let shield: InputShield
  private let standIn: CursorStandIn
  private let showDuration: () -> TimeInterval
  /// Whether returning items must wait, e.g. while MyBar's bar is open: the
  /// drags would close it under the person's cursor.
  var holdsReturns: () -> Bool = { false }
  private var restoreTask: Task<Void, Never>?

  /// Items shown temporarily, with the section to return them to. Saved so
  /// that they are put back even if MyBar quits before their menus close.
  private var pending: [ItemKey: MenuBarSection] {
    get {
      let raw = UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]
      return Dictionary(
        uniqueKeysWithValues: raw.compactMap { key, value in MenuBarSection(rawValue: value).map { (ItemKey(key), $0) }
        })
    }
    set {
      let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.rawValue) })
      UserDefaults.standard.set(raw, forKey: Self.pendingKey)
    }
  }

  init(
    statusItems: StatusItems, mover: ItemMover, curtain: MenuBarCurtain, shield: InputShield,
    standIn: CursorStandIn, showDuration: @escaping () -> TimeInterval
  ) {
    self.statusItems = statusItems
    self.mover = mover
    self.curtain = curtain
    self.shield = shield
    self.standIn = standIn
    self.showDuration = showDuration
  }

  /// How many earlier items may stay out while another is opened.
  private static let maximumLeftOut = 2

  /// Whether an activation or return is under way.
  var isBusy: Bool { runningCount > 0 }
  private var runningCount = 0

  /// Activations and returns run one at a time, in order; overlapping moves
  /// would undo each other.
  private var queue: Task<Void, Never>?

  private func serially<T>(_ work: @escaping @MainActor () async -> T) async -> T {
    let previous = queue
    runningCount += 1
    let task = Task { @MainActor in
      await previous?.value
      defer { self.runningCount -= 1 }
      return await work()
    }
    queue = Task { _ = await task.value }
    return await task.value
  }

  /// Opens the item with `key`. `known` is the snapshot the request was made
  /// from (the bar's), used if a fresh scan can't place the item yet.
  /// `beforePress` runs just before the item is clicked, for the caller to
  /// put away whatever showed the item.
  func activate(
    _ key: ItemKey, secondary: Bool = false, known: MenuBarSnapshot? = nil,
    beforePress: @escaping @MainActor () -> Void = {}
  ) async -> Bool {
    restoreTask?.cancel()
    generation += 1
    return await serially { [self] in
      await performActivation(key, secondary: secondary, known: known, beforePress: beforePress)
    }
  }

  private func performActivation(
    _ key: ItemKey, secondary: Bool, known: MenuBarSnapshot?, beforePress: () -> Void
  ) async -> Bool {
    if MenuBarSystem.usesAgent {
      knownItem = known?.item(for: key)
      return await pressInPlace(key, secondary: secondary, beforePress: beforePress)
    }
    var watch = Stopwatch("activate")
    // Hold the person's clicks back and keep the pointer looking still from
    // the first move until the click; the click itself takes the cursor to
    // the menu bar too.
    shield.raise()
    await standIn.raise()
    var covered = false
    var holding = true
    defer {
      if covered { curtain.lower() }
      if holding {
        standIn.lower()
        shield.lower()
      }
      watch.lap("done")
    }
    restoreTask?.cancel()

    // The snapshot the request came from is recent; refreshing its positions
    // from the window server is enough. Scan only when it doesn't know the item.
    var base: MenuBarSnapshot
    if let known, known.item(for: key) != nil,
      known.display
        == MenuBarScanner.activeDisplay(
          windows: MenuBarScanner.statusWindows(), mapping: MenuBarScanner.displayMapping())
    {
      base = known.withCurrentFrames()
    } else {
      base = await MenuBarScanner.scanAsync()
    }
    watch.lap("scan")
    guard var item = base.item(for: key) else { return false }
    let section = base.section(of: item)
    if section != .visible {
      // Covered from here until the click, so the menu bar changes once:
      // straight to the item, open.
      await curtain.raise()
      covered = true
    }

    // Items earlier activations left out (their menus closed when this item
    // was clicked) go back together once their menus have been closed for a
    // while. Put back now, each would take the space next to the notch and
    // push this item further behind it; but too many left out would crowd
    // that space until no item can come out, so past a few, put them back
    // first, in the same session.
    var saved = pending
    let others = saved.filter { $0.key != key }
    let returning = others.count >= Self.maximumLeftOut ? others : [:]
    var moves = returning.map { ($0.key, $0.value) }
    if section != .visible { moves.append((key, .visible)) }
    let failures = moves.isEmpty ? [:] : await mover.perform(moves, known: base, allowOtherDisplay: false)
    watch.lap("moves")
    for (returned, _) in returning where failures[returned] == nil || !Self.isRunning(returned) {
      saved[returned] = nil
    }

    let current = base.withCurrentFrames()
    if section != .visible {
      if failures[key] == nil, let moved = current.item(for: key), current.section(of: moved) == .visible {
        saved[key] = saved[key] ?? section
        item = moved
      } else {
        // Expanding the menu bar would expose every item; press it where it is.
        Log.app.info("\(key.rawValue) could not be shown on its own; pressing it through Accessibility")
        item = current.item(for: key) ?? item
      }
    } else {
      item = current.item(for: key) ?? item
    }
    pending = saved

    beforePress()
    let pressed = await press(item, secondary: secondary)
    watch.lap("pressed")
    // The menu is open: give the person their mouse back, and lift the cover
    // once the menu bar has settled.
    standIn.lower()
    shield.lower()
    holding = false
    if covered { await mover.waitForCollapse() }
    scheduleRestore(after: item)
    return pressed
  }

  /// Conceals items on macOS 27+ (see `Concealer`).
  var concealer: Concealer?
  /// The item as the request's snapshot knew it.
  private var knownItem: MenuBarItem?

  /// On macOS 27+ a hidden item isn't in the menu bar at all: its app is
  /// allowed back for a moment, the item appears in its own place, is
  /// pressed there (through Accessibility, so the pointer stays put), and
  /// is concealed again once its menu has been closed for a while.
  private func pressInPlace(_ key: ItemKey, secondary: Bool, beforePress: () -> Void) async -> Bool {
    var watch = Stopwatch("activate")
    guard let concealer else { return false }
    restoreTask?.cancel()
    // Only one item out at a time: put back whatever was opened before.
    await concealer.concealAllRevealed()
    // The bar's last scan knows the item; scan only if it doesn't.
    var known = knownItem
    if known?.key != key || AgentScanner.element(for: key) == nil {
      known = await MenuBarScanner.scanAsync().item(for: key)
    }
    guard var item = known else { return false }
    let concealed = concealer.section(of: key) != .visible
    if concealed, SystemModules.preferenceKey(for: key) != nil {
      // A hidden Control Center item comes back as a new element: wait for
      // it to be listed again.
      await concealer.reveal(key)
      for _ in 0..<15 {
        await sleep(milliseconds: 100)
        if let shown = await MenuBarScanner.scanAsync().item(for: key), shown.frame.minX >= 0 {
          item = shown
          break
        }
      }
      // Its menu can only open once it has settled in.
      await sleep(milliseconds: 250)
      watch.lap("shown")
    } else if concealed {
      let before = item.frame
      await concealer.reveal(key)
      watch.lap("revealed")
      // Accessibility keeps reporting a concealed item where it last was;
      // it moves once the item is back in the menu bar (if its place
      // changed at all), which takes a few hundred milliseconds.
      if let element = MenuBarScanner.element(for: item) {
        for _ in 0..<6 {
          await sleep(milliseconds: 50)
          if let frame = AX.frame(of: element), frame != before {
            item = MenuBarItem(
              window: WindowInfo(
                windowID: item.window.windowID, frame: frame, title: item.window.title, ownerPID: item.window.ownerPID,
                ownerName: item.window.ownerName, isOnScreen: true), owner: item.owner, key: item.key)
            break
          }
        }
      }
      watch.lap("shown")
    }
    beforePress()
    guard let element = MenuBarScanner.element(for: item) else { return false }
    let action = (secondary ? "AXShowMenu" : kAXPressAction) as String
    let wrapped = AgentScanner.UncheckedElement(element: element)
    // The press can wait for the menu to close; keep MyBar responsive.
    let result = await Task.detached(priority: .userInitiated) {
      AXUIElementSetMessagingTimeout(wrapped.element, 1)
      return AXUIElementPerformAction(wrapped.element, action as CFString)
    }.value
    watch.lap("pressed")
    if concealed { scheduleConcealing(key, shownAt: item) }
    // "Cannot complete" also comes back when the menu opened and is being tracked.
    return result == .success || result == .cannotComplete
  }

  /// Conceals the item with `key` again once its menu or popover has been
  /// closed for `showDuration`.
  private func scheduleConcealing(_ key: ItemKey, shownAt item: MenuBarItem) {
    let duration = showDuration()
    restoreTask = Task { [weak self] in
      await sleep(milliseconds: 800)
      var closedSince: Date?
      while !Task.isCancelled {
        if self?.holdsReturns() == true {
          await sleep(milliseconds: 300)
          continue
        }
        if MenuState.isShowingUI(of: item.owner?.pid, near: item.frame) {
          closedSince = nil
        } else if let since = closedSince {
          if Date().timeIntervalSince(since) >= duration { break }
        } else {
          closedSince = Date()
        }
        await sleep(milliseconds: 300)
      }
      guard !Task.isCancelled else { return }
      await self?.concealer?.conceal(key)
    }
  }

  /// Returns items left out by a previous run to their sections.
  func restoreAfterLaunch() {
    guard !pending.isEmpty else { return }
    restoreTask = Task { await restore() }
  }

  /// Bumped by every activation, so a return that was already waiting its
  /// turn doesn't send back the item that was just opened.
  private var generation = 0

  private func restore() async {
    let requested = generation
    await serially { [self] in
      guard requested == generation else { return }
      let returning = pending
      guard !returning.isEmpty else { return }
      let failures = await mover.perform(returning.map { ($0.key, $0.value) })
      var saved = pending
      // An item whose app quit has nothing left to restore; others are retried later.
      for (key, _) in returning where failures[key] == nil || !Self.isRunning(key) {
        saved[key] = nil
      }
      pending = saved
    }
  }

  /// Whether the app that owns the item with `key` (`bundle/identifier`) runs.
  private static func isRunning(_ key: ItemKey) -> Bool {
    let bundle = key.rawValue.split(separator: "/").first.map(String.init) ?? ""
    return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundle }
  }

  private func press(_ item: MenuBarItem, secondary: Bool) async -> Bool {
    let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
    if !secondary, item.window.isOnScreen, ItemMover.isReachable(item.frame) {
      await EventDriver.clickAsync(at: center)
      return true
    }
    if let element = MenuBarScanner.element(for: item) {
      let action = secondary ? "AXShowMenu" : kAXPressAction
      return AXUIElementPerformAction(element, action as CFString) == .success
    }
    return false
  }

  /// Once the item's menu or popover has been closed for a while, returns
  /// temporarily shown items and collapses any section expanded for the fallback.
  private func scheduleRestore(after item: MenuBarItem) {
    let duration = showDuration()
    let task = Task { [weak self] in
      // Give the menu or popover time to appear before watching for it to close.
      await sleep(milliseconds: 800)
      var closedSince: Date?
      while !Task.isCancelled {
        if self?.holdsReturns() == true {
          await sleep(milliseconds: 300)
          continue
        }
        let current = MenuBarScanner.statusWindows().first { $0.windowID == item.window.windowID }?.frame ?? item.frame
        if MenuState.isShowingUI(of: item.owner?.pid, near: current) {
          closedSince = nil
        } else if let since = closedSince {
          if Date().timeIntervalSince(since) >= duration { break }
        } else {
          closedSince = Date()
        }
        await sleep(milliseconds: 300)
      }
      guard !Task.isCancelled, let self else { return }
      self.statusItems.setLevel(.none, for: Self.source)
      await self.restore()
    }
    restoreTask = task
  }
}

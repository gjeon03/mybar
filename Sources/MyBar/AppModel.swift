import AppKit
import MyBarCore
import SwiftUI

enum SettingsTab: String, Hashable {
  case layout
  case groups
  case general
  case permissions
}

/// Ties MyBar's status items, scanner, mover and panels together, and holds
/// the state the settings window shows.
@MainActor
final class AppModel: ObservableObject {
  static let settingsKey = "MyBarSettings"
  private static let userRevealSource = "user"

  @Published var settings: MyBarSettings {
    didSet { settingsChanged(from: oldValue) }
  }
  @Published private(set) var snapshot = MenuBarSnapshot()
  @Published private(set) var imageVersion = 0
  @Published private(set) var busyMessage: String?
  @Published var lastError: String?
  @Published private(set) var accessibilityGranted = Permissions.accessibility
  @Published private(set) var screenRecordingGranted = Permissions.screenRecording
  @Published var settingsTab: SettingsTab = .layout

  let statusItems: StatusItems
  let images = ItemImages()
  private let panel = BarPanelController()
  private let groupItems = GroupItems()
  private let hotkey = Hotkey()
  private let curtain = MenuBarCurtain()
  private let shield = InputShield()
  private let standIn = CursorStandIn()
  private lazy var mover = ItemMover(statusItems: statusItems, curtain: curtain, shield: shield, standIn: standIn)
  private lazy var activator = ItemActivator(
    statusItems: statusItems, mover: mover, curtain: curtain, shield: shield, standIn: standIn
  ) { [weak self] in
    self?.settings.activationShowDuration ?? 5
  }
  private lazy var settingsWindow = SettingsWindowController(model: self)
  private var rehideTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var permissionTimer: Timer?
  private var thoroughScanTimer: Timer?
  #if DEBUG
    private var debugControl: DebugControl?
  #endif

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
      let saved = try? JSONDecoder().decode(MyBarSettings.self, from: data)
    {
      settings = saved
    } else {
      settings = MyBarSettings()
    }
    statusItems = StatusItems()
  }

  func start() {
    statusItems.controlIcon = settings.controlIcon
    statusItems.onControlClick = { [weak self] event in self?.handleControlClick(event) }
    groupItems.onClick = { [weak self] id, item, event in self?.handleGroupClick(id, item: item, event: event) }
    panel.onSelect = { [weak self] key, event in self?.activate(key, secondary: event.type == .rightMouseUp) }
    // A click on the bar, or on MyBar's icon, made while MyBar was busy is
    // acted on next.
    shield.onHeldClick = { [weak self] point in
      guard let self else { return }
      if let key = self.panel.entry(at: point) {
        self.activate(key)
      } else if MenuBarSystem.usesAgent, self.notificationCenter.isOnClock(point) {
        self.notificationCenter.toggle()
      } else if MenuBarScanner.statusWindows().first(where: { $0.title == OwnItemName.control })?.frame.contains(point)
        == true
      {
        self.toggleReveal(includeAlwaysHidden: false)
      }
    }
    activator.holdsReturns = { [weak self] in self?.panel.isShown ?? false }
    hotkey.action = { [weak self] in self?.toggleReveal(includeAlwaysHidden: false) }
    hotkey.setEnabled(settings.hotkeyEnabled)
    groupItems.sync(settings.groups)
    #if DEBUG
      debugControl = DebugControl(model: self)
    #endif

    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleRefresh() }
      }
    }
    if !accessibilityGranted {
      Permissions.requestAccessibility()
    }
    // Without Screen Recording, macOS withholds the names of menu bar items
    // (MyBar finds its dividers by them) and the cover can't be pictured.
    if !screenRecordingGranted {
      _ = CGRequestScreenCaptureAccess()
    }
    if !settings.hasCompletedOnboarding || !accessibilityGranted || !screenRecordingGranted {
      settingsTab = accessibilityGranted && screenRecordingGranted ? .layout : .permissions
      openSettings()
    }
    scheduleRefresh(after: 600)
    // Now and then ask every app again, in case one added a menu bar item.
    thoroughScanTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.snapshot = await MenuBarScanner.scanAsync(thorough: true)
      }
    }
    Task { [weak self] in
      await sleep(milliseconds: 1500)
      self?.activator.restoreAfterLaunch()
    }
    if MenuBarSystem.usesAgent { startConcealing() }
  }

  /// On macOS 27+ items are concealed through MenuBarAgent (see `Concealer`).
  private(set) lazy var concealer = Concealer(concealed: settings.concealedApps)
  /// Opens Notification Center from the clock, which the concealment blocks.
  private lazy var notificationCenter = NotificationCenterBridge(concealer: concealer, curtain: curtain)

  /// Redraws MyBar's icon (after its picture was replaced).
  func refreshControlIcon() {
    statusItems.controlIcon = settings.controlIcon
  }

  /// Puts back what doesn't put itself back when MyBar quits: Control
  /// Center's items hidden through its preferences.
  func prepareToQuit() {
    if MenuBarSystem.usesAgent { concealer.restoreSystemModules() }
  }

  private func startConcealing() {
    #if DEBUG
      if ProcessInfo.processInfo.environment["MYBAR_NO_CONCEAL"] == "1" { return }
    #endif
    concealer.onChange = { [weak self] concealed in self?.settings.concealedApps = concealed }
    mover.concealer = concealer
    activator.concealer = concealer
    // Concealed items aren't drawn; picture them whenever they are.
    mover.pictureBeforeConcealing = { [weak self] key in
      guard let self, let item = await MenuBarScanner.scanAsync().item(for: key) else { return }
      _ = await self.images.refreshFromScreen([item])
    }
    if !concealer.isAvailable {
      lastError = "This version of macOS doesn't let MyBar hide menu bar items."
    } else {
      notificationCenter.start()
    }
    Task { [weak self] in
      guard let self else { return }
      // Until the restriction is applied every item is drawn as usual:
      // picture the concealed ones that need it first.
      let snapshot = await MenuBarScanner.scanAsync()
      let stale = self.images.keysNeedingCapture(
        snapshot.items.filter { snapshot.section(of: $0) != .visible }.map(\.key))
      let chevron = await Task.detached { AgentScanner.chevron() }.value
      var drawn = snapshot.items.filter { stale.contains($0.key) && !AgentLayout.isFolded($0.frame, chevron: chevron) }
      if !drawn.isEmpty {
        // Right after a launch the menu bar may still be bringing back the
        // items an earlier MyBar concealed, and their reported frames lag
        // behind: picture only items that have stayed put and don't overlap
        // another one.
        await sleep(milliseconds: 400)
        let later = await MenuBarScanner.scanAsync()
        drawn = drawn.filter { item in
          later.item(for: item.key)?.frame == item.frame
            && !later.items.contains { $0.key != item.key && $0.frame.intersects(item.frame) }
        }
      }
      if !drawn.isEmpty { _ = await self.images.refreshFromScreen(drawn) }
      await self.concealer.apply()
      await self.refresh()
    }
  }

  // MARK: - Settings

  private func settingsChanged(from old: MyBarSettings) {
    if settings.controlIcon != old.controlIcon { statusItems.controlIcon = settings.controlIcon }
    if let data = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }
    if old.hotkeyEnabled != settings.hotkeyEnabled {
      hotkey.setEnabled(settings.hotkeyEnabled)
    }
    if old.groups != settings.groups {
      let created = groupItems.sync(settings.groups)
      placeNewGroupItems(created)
    }
  }

  // MARK: - Scanning

  func refresh() async {
    var scanned = await MenuBarScanner.scanAsync()
    if scanned.dividers.hidden == nil {
      // Right after the menu bar changed (or switched displays) MyBar's own
      // windows can briefly be missing; without them every item looks visible.
      await sleep(milliseconds: 150)
      scanned = await MenuBarScanner.scanAsync()
    }
    snapshot = scanned
    accessibilityGranted = Permissions.accessibility
    screenRecordingGranted = Permissions.screenRecording
    await images.refresh(snapshot.items)
    imageVersion += 1
  }

  func scheduleRefresh(after milliseconds: UInt64 = 800) {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      await sleep(milliseconds: milliseconds)
      guard !Task.isCancelled else { return }
      await self?.refresh()
    }
  }

  func image(for item: MenuBarItem) -> NSImage { images.image(for: item) }

  /// Items of a section in menu bar order (left to right).
  func items(in section: MenuBarSection) -> [MenuBarItem] {
    snapshot.sections[section] ?? []
  }

  var allItems: [MenuBarItem] { snapshot.items.sorted { $0.frame.minX < $1.frame.minX } }

  // MARK: - Revealing

  private func handleControlClick(_ event: NSEvent) {
    Log.app.debug("control click \(event.type.rawValue) at \(event.timestamp)")
    if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
      showControlMenu()
      return
    }
    let includeAlways = event.modifierFlags.contains(.option) && settings.optionClickShowsAlwaysHidden
    toggleReveal(includeAlwaysHidden: includeAlways)
  }

  func toggleReveal(includeAlwaysHidden: Bool) {
    switch settings.revealStyle {
    case .bar:
      if panel.isShown, panel.context == "main" {
        panel.close()
      } else {
        Task { await showMainBar(includeAlwaysHidden: includeAlwaysHidden) }
      }
    case .menuBar:
      if statusItems.level(for: Self.userRevealSource) != .none {
        collapseMenuBar()
      } else {
        expandMenuBar(includeAlwaysHidden: includeAlwaysHidden)
      }
    }
  }

  private func showMainBar(includeAlwaysHidden: Bool) async {
    var watch = Stopwatch("show bar")
    snapshot = await MenuBarScanner.scanAsync()
    watch.lap("scan")
    defer { watch.lap("presented") }
    var sections: [MenuBarSection] = [.hidden]
    if includeAlwaysHidden { sections.insert(.alwaysHidden, at: 0) }
    var shown = sections.flatMap { items(in: $0) }
    if settings.hideGroupMembersFromBar {
      shown.removeAll { settings.group(containing: $0.key) != nil }
    }
    guard let anchor = snapshot.controlItem?.frame ?? statusItems.controlFrame else { return }
    present(shown, anchor: anchor, title: nil, context: "main")
  }

  /// While the bar is open, keeps a fresh picture of the menu bars ready,
  /// so opening an item can cover them without waiting for a capture.
  private var curtainPreparation: Task<Void, Never>?

  private func keepCurtainReady() {
    curtainPreparation?.cancel()
    curtainPreparation = Task { [weak self] in
      while !Task.isCancelled, let self, self.panel.isShown {
        await self.curtain.prepare()
        await sleep(milliseconds: 1000)
      }
    }
  }

  private func present(_ items: [MenuBarItem], anchor: CGRect, title: String?, context: String) {
    let keys = items.map(\.key)
    let entries = items.map { BarEntry(key: $0.key, name: $0.displayName, image: images.image(for: $0)) }
    panel.show(
      entries: entries, anchor: anchor, title: title, context: context,
      prefersDark: images.prefersDarkBackground(for: keys))
    keepCurtainReady()
    captureTask = Task {
      let stale = images.keysNeedingCapture(keys)
      if stale.isEmpty {
        await images.refresh(items)
      } else {
        await capturePass(items.filter { stale.contains($0.key) })
      }
      for item in items { panel.updateImage(images.image(for: item), for: item.key) }
      imageVersion += 1
    }
  }

  private static let captureRevealSource = "capture"
  private var isCapturing = false
  /// Picturing the bar's items; cancelled when an item is opened, as both
  /// rearrange the menu bar.
  private var captureTask: Task<Void, Never>?

  /// Hidden items are not drawn while they are off screen, so to picture them
  /// MyBar briefly expands every section, captures what became visible and
  /// collapses again.
  private func capturePass(_ items: [MenuBarItem]) async {
    guard !isCapturing, Permissions.screenRecording, !MenuState.isAnyMenuOpen() else { return }
    isCapturing = true
    let started = Date()
    defer {
      isCapturing = false
      Log.app.debug("capture pass for \(items.count) items took \(Date().timeIntervalSince(started))s")
    }
    images.markAttempted(items.map(\.key))
    // On macOS 27+ concealed items are pictured while they are drawn as
    // usual: at launch, before concealing, and just before being concealed.
    // (Shown for a moment, Accessibility reports them off from where they
    // are drawn, so they can't be pictured then.)
    if MenuBarSystem.usesAgent { return }
    await curtain.raise()
    statusItems.setLevel(.all, for: Self.captureRevealSource)
    defer {
      statusItems.setLevel(.none, for: Self.captureRevealSource)
      Task { [curtain] in
        await sleep(milliseconds: 250)
        curtain.lower()
      }
    }
    // Wait until the dividers have shrunk, then give items time to draw.
    for _ in 0..<10 {
      await sleep(milliseconds: 80)
      let divider = MenuBarScanner.statusWindows().first { $0.title == OwnItemName.hidden }
      if (divider?.frame.width ?? 0) < StatusItems.collapsedLength / 10 { break }
    }
    await sleep(milliseconds: 200)
    guard !Task.isCancelled else {
      images.forgetAttempts(items.map(\.key))
      return
    }
    // Frames changed while expanded; capture by the current layout. Some
    // apps redraw slowly, so try the ones that came back blank once more.
    let current = Self.withCurrentFrames(items)
    let captured = await images.refresh(current)
    let missing = current.filter { !captured.contains($0.key) }
    if !missing.isEmpty, !Task.isCancelled {
      await sleep(milliseconds: 250)
      await images.refresh(Self.withCurrentFrames(missing))
    }
  }

  /// `items` with their windows' frames as they are right now.
  private static func withCurrentFrames(_ items: [MenuBarItem]) -> [MenuBarItem] {
    let windows = Dictionary(
      MenuBarScanner.statusWindows().map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
    return items.compactMap { item in
      windows[item.window.windowID].map { MenuBarItem(window: $0, owner: item.owner, key: item.key) }
    }
  }

  private func expandMenuBar(includeAlwaysHidden: Bool) {
    statusItems.setLevel(includeAlwaysHidden ? .all : .hidden, for: Self.userRevealSource)
    if MenuBarSystem.usesAgent {
      Task { await concealer.revealAll(for: Self.userRevealSource) }
    }
    scheduleRefresh(after: 500)
    rehideTask?.cancel()
    let delay = settings.autoRehideDelay
    rehideTask = Task { [weak self] in
      await sleep(milliseconds: UInt64(delay * 1000))
      while !Task.isCancelled, MenuState.isAnyMenuOpen() || Self.isMouseInMenuBar() {
        await sleep(milliseconds: 500)
      }
      guard !Task.isCancelled else { return }
      self?.collapseMenuBar()
    }
  }

  private func collapseMenuBar() {
    rehideTask?.cancel()
    if MenuBarSystem.usesAgent {
      Task { await concealer.endRevealAll(for: Self.userRevealSource) }
    }
    statusItems.setLevel(.none, for: Self.userRevealSource)
  }

  private static func isMouseInMenuBar() -> Bool {
    let location = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return false }
    return location.y >= screen.visibleFrame.maxY
  }

  func activate(_ key: ItemKey, secondary: Bool = false) {
    // On macOS 27+ opening an item takes Accessibility alone.
    guard Permissions.accessibility, MenuBarSystem.usesAgent || Permissions.screenRecording else {
      // Moving items would fail, in plain sight; ask for what's missing.
      panel.close()
      settingsTab = .permissions
      openSettings()
      return
    }
    // Keep the bar up, with the entry highlighted, until the item opens.
    panel.markOpening(key)
    let capture = captureTask
    capture?.cancel()
    Task {
      // Let a capture in progress collapse the menu bar first.
      await capture?.value
      let ok = await activator.activate(key, secondary: secondary, known: snapshot) { [weak self] in
        self?.panel.close()
      }
      panel.close()
      if !ok {
        NSSound.beep()
        lastError = "Could not open the item. It may have quit or moved."
      }
    }
  }

  // MARK: - Diagnostics

  /// Copies a report about the menu bar to the clipboard, for someone to
  /// send when MyBar doesn't work on their Mac.
  func copyDiagnostics() {
    let report = Diagnostics.report(statusItems: statusItems, snapshot: snapshot)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(report, forType: .string)
  }

  // MARK: - Groups

  private func handleGroupClick(_ id: UUID, item: NSStatusItem, event: NSEvent) {
    guard let group = settings.groups.first(where: { $0.id == id }) else { return }
    if event.type == .rightMouseUp {
      settingsTab = .groups
      openSettings()
      return
    }
    if panel.isShown, panel.context == id.uuidString {
      panel.close()
      return
    }
    Task {
      snapshot = await MenuBarScanner.scanAsync()
      let members = group.memberKeys.compactMap { snapshot.item(for: $0) }
      let anchor =
        snapshot.groupItems[group.autosaveName]?.frame
        ?? item.button?.window?.frame.flippedToWindowServer
        ?? .zero
      present(members, anchor: anchor, title: group.name, context: id.uuidString)
    }
  }

  func addGroup() -> UUID {
    let group = ItemGroup(name: "Group \(settings.groups.count + 1)")
    settings.groups.append(group)
    return group.id
  }

  func deleteGroup(_ id: UUID) {
    settings.groups.removeAll { $0.id == id }
  }

  func setMembership(_ key: ItemKey, group id: UUID, isMember: Bool) {
    settings.assign(key, toGroup: isMember ? id : nil)
  }

  /// Hides a group's members so that they only appear through the group.
  func hideMembers(of id: UUID) {
    guard let group = settings.groups.first(where: { $0.id == id }) else { return }
    let visible = group.memberKeys.filter { key in
      snapshot.item(for: key).map { snapshot.section(of: $0) == .visible } ?? false
    }
    move(visible, to: .hidden)
  }

  /// New group items are seeded next to MyBar's icon; if macOS placed one
  /// elsewhere, drag it into the visible section.
  private func placeNewGroupItems(_ names: [String]) {
    guard !names.isEmpty else { return }
    Task {
      await sleep(milliseconds: 500)
      let current = await MenuBarScanner.scanAsync()
      let misplaced = names.filter { name in
        current.groupItems[name].map { current.section(of: $0) != .visible } ?? false
      }
      guard !misplaced.isEmpty else { return }
      busyMessage = "Placing group icon…"
      for name in misplaced {
        do {
          try await mover.placeGroupItem(named: name)
        } catch {
          lastError =
            "Couldn't place the group icon automatically: \(error.localizedDescription) "
            + "Hold ⌘ and drag it next to MyBar's icon."
        }
      }
      busyMessage = nil
      await refresh()
    }
  }

  // MARK: - Moving

  /// Apple's own items (Wi-Fi, Battery, Sound, input sources…) that are not
  /// in the visible section and can be moved there.
  var hiddenAppleItems: [ItemKey] {
    snapshot.items.filter { item in
      item.bundleID?.hasPrefix("com.apple.") == true && snapshot.section(of: item) != .visible
        && !ItemMover.isFixed(item)
    }.map(\.key)
  }

  func keepAppleItemsVisible() {
    move(hiddenAppleItems, to: .visible)
  }

  func move(_ keys: [ItemKey], to section: MenuBarSection) {
    Task { await moveAndWait(keys, to: section) }
  }

  func moveAndWait(_ keys: [ItemKey], to section: MenuBarSection) async {
    guard !keys.isEmpty else { return }
    lastError = nil
    busyMessage = "Moving \(keys.count == 1 ? "item" : "\(keys.count) items")…"
    let failures = await mover.move(keys, to: section)
    busyMessage = nil
    if let first = failures.values.first {
      lastError = first.localizedDescription
    }
    await refresh()
  }

  // MARK: - Settings window and menu

  func openSettings() {
    settingsWindow.show()
    startPermissionPolling()
    Task { await refresh() }
  }

  func settingsWindowClosed() {
    permissionTimer?.invalidate()
    permissionTimer = nil
    if !settings.hasCompletedOnboarding, accessibilityGranted {
      settings.hasCompletedOnboarding = true
    }
  }

  private func startPermissionPolling() {
    permissionTimer?.invalidate()
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let ax = Permissions.accessibility
        let sc = Permissions.screenRecording
        if ax != self.accessibilityGranted || sc != self.screenRecordingGranted {
          self.accessibilityGranted = ax
          self.screenRecordingGranted = sc
          Task { await self.refresh() }
        }
      }
    }
  }

  private func showControlMenu() {
    let menu = NSMenu()
    let showAll = NSMenuItem(title: "Show All Items", action: #selector(MenuActions.showAll), keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(MenuActions.settings), keyEquivalent: ",")
    let quit = NSMenuItem(title: "Quit MyBar", action: #selector(MenuActions.quit), keyEquivalent: "q")
    for item in [showAll, settingsItem, quit] { item.target = MenuActions.shared }
    MenuActions.shared.model = self
    menu.addItem(showAll)
    menu.addItem(.separator())
    menu.addItem(settingsItem)
    menu.addItem(quit)
    guard let button = statusItems.control.button else { return }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
  }

  fileprivate func showAllItems() {
    switch settings.revealStyle {
    case .bar: Task { await showMainBar(includeAlwaysHidden: true) }
    case .menuBar: expandMenuBar(includeAlwaysHidden: true)
    }
  }
}

/// Target for the control item's context menu.
@MainActor
private final class MenuActions: NSObject {
  static let shared = MenuActions()
  weak var model: AppModel?

  @objc func showAll() { model?.showAllItems() }
  @objc func settings() { model?.openSettings() }
  @objc func quit() { NSApp.terminate(nil) }
}

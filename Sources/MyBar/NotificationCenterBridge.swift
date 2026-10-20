import AppKit
import os

/// Opens Notification Center from the menu bar clock on macOS 27+.
///
/// While MenuBarAgent's allowed list is in force (see `Concealer`), the
/// system ignores the clock, so Notification Center can't be opened from it.
/// MyBar takes clicks on the clock instead: it covers the menu bar, lifts
/// the restriction, presses the clock for the person and, once Notification
/// Center has opened or closed, restores the restriction and uncovers the
/// menu bar. Notification Center stays open under the restriction, and the
/// clock can be pressed as soon as the restriction is gone.
///
/// Clicks set where Notification Center should end up (each one flips it),
/// and MyBar presses the clock until it gets there: pressed while it is
/// still sliding in or out, Notification Center doesn't reliably follow.
@MainActor
final class NotificationCenterBridge {
  nonisolated static let clockIdentifier = "com.apple.menuextra.clock"
  private static let notificationCenterBundleID = "com.apple.notificationcenterui"

  private let concealer: Concealer
  private let curtain: MenuBarCurtain
  private var tap: ClockTap?
  private var refreshTimer: Timer?
  /// Work started when the button goes down on the clock, so that by the
  /// time it comes up the menu bar can be covered and the clock pressed at
  /// once.
  private var preparation: Task<AgentScanner.Clock?, Never>?
  /// Whether Notification Center should end up open, while clicks come in.
  private var wantsOpen: Bool?
  /// Pressing the clock until Notification Center is where it should be.
  private var driving: Task<Void, Never>?
  /// Putting the restriction back and uncovering the menu bar; called off
  /// by another click.
  private var restoring: Task<Void, Never>?
  private var isCovered = false
  private var isLifted = false
  private var liftedAt: ContinuousClock.Instant?
  private var clickCount = 0

  init(concealer: Concealer, curtain: MenuBarCurtain) {
    self.concealer = concealer
    self.curtain = curtain
  }

  /// Watches the clock from now on. Watching clicks takes Accessibility, so
  /// until it is granted MyBar keeps trying.
  func start() {
    guard refreshTimer == nil else { return }
    watch()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.watch() }
    }
  }

  private func watch() {
    if tap == nil {
      let tap = ClockTap { [weak self] isDown in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            if isDown { self?.prepare() } else { self?.toggle() }
          }
        }
      }
      guard tap.start() else { return }
      self.tap = tap
      Log.app.info("watching the clock for Notification Center")
    }
    updateClockFrame()
  }

  /// Whether `point` (window-server coordinates) is on the clock.
  func isOnClock(_ point: CGPoint) -> Bool {
    tap?.isOnClock(point) == true
  }

  private func updateClockFrame() {
    Task { [weak self] in
      let frame = await Task.detached { AgentScanner.clock()?.frame }.value
      self?.tap?.clockFrame = frame
    }
  }

  /// The button went down on the clock: cover the menu bar and lift the
  /// restriction now, so the clock can be pressed the moment it comes up.
  private func prepare() {
    restoring?.cancel()
    restoring = nil
    clickCount += 1
    let count = clickCount
    preparation = Task {
      async let clock = Task.detached { AgentScanner.clock() }.value
      if !isCovered || !curtain.isRaised {
        isCovered = true
        await curtain.raise()
        await curtain.waitUntilShown()
      } else {
        curtain.keepUp()
      }
      if !isLifted {
        isLifted = true
        concealer.suspend()
        liftedAt = .now
      }
      return await clock
    }
    // Should the button-up never arrive, put everything back.
    Task {
      await sleep(milliseconds: 3000)
      if count == clickCount, driving == nil { scheduleRestore() }
    }
  }

  /// A click on the clock (button up): flips where Notification Center
  /// should end up and gets it there.
  func toggle() {
    if preparation == nil { prepare() }
    let prepared = preparation
    preparation = nil
    wantsOpen = !(wantsOpen ?? Self.isNotificationCenterOpen())
    guard driving == nil else { return }
    driving = Task {
      var clock = await prepared?.value
      // A click may come in just as Notification Center gets where it
      // should be; go on until no click is left unanswered.
      for _ in 0..<3 {
        await drive(clock: clock)
        clock = nil
        guard let target = wantsOpen, Self.isNotificationCenterOpen() != target else { break }
      }
      driving = nil
      wantsOpen = nil
      scheduleRestore()
    }
  }

  private func drive(clock prepared: AgentScanner.Clock?) async {
    var watch = Stopwatch("notification center")
    // The concealed items come back when the restriction is lifted, and
    // a press made while the menu bar rearranges itself is often ignored.
    let lifted = ContinuousClock.now - (liftedAt ?? .now)
    if lifted < Self.liftSettle { try? await Task.sleep(for: Self.liftSettle - lifted) }
    watch.lap("restriction lifted")
    var clock = prepared
    for round in 0..<4 {
      guard let target = wantsOpen else { return }
      // Nothing was moving when the first click came in.
      let state = round == 0 ? Self.isNotificationCenterOpen() : await Self.settledState()
      if state == target {
        if wantsOpen == target {
          watch.lap(target ? "opened" : "closed")
          return
        }
        continue
      }
      if clock == nil { clock = await Task.detached { AgentScanner.clock() }.value }
      // The person's own click, sent again, is what the menu bar answers
      // most reliably; pressing through Accessibility is often ignored. The
      // pointer is still on the clock after a click there.
      let pointer = CGEvent(source: nil)?.location ?? .zero
      let pressed: Bool
      if let frame = clock?.frame, frame.contains(pointer) {
        Self.replayClick(at: pointer)
        pressed = true
      } else if let element = clock?.element {
        pressed = await Task.detached { AX.press(element) }.value
      } else {
        pressed = false
      }
      if !pressed {
        // The clock's element goes stale while the menu bar rearranges
        // itself; look it up again.
        clock = nil
        await sleep(milliseconds: 100)
        continue
      }
      // Opening shows its panel within about 150 ms of the press; closing
      // takes it away once the panel has slid out.
      for _ in 0..<14 {
        await sleep(milliseconds: 50)
        if Self.isNotificationCenterOpen() == target { break }
      }
    }
    Log.app.error("pressing the clock didn't get Notification Center open or closed")
  }

  /// Clicks at `point` as the person did; MyBar's own events get past the
  /// clock watch.
  private static func replayClick(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
      guard
        let event = CGEvent(
          mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
      else { continue }
      event.setIntegerValueField(.eventSourceUserData, value: InputShield.marker)
      event.post(tap: .cghidEventTap)
    }
  }

  /// Whether Notification Center is open, once two looks a moment apart agree.
  private static func settledState() async -> Bool {
    var last = isNotificationCenterOpen()
    for _ in 0..<8 {
      await sleep(milliseconds: 80)
      let now = isNotificationCenterOpen()
      if now == last { return now }
      last = now
    }
    return last
  }

  private static let liftSettle: Duration = .milliseconds(200)
  /// MenuBarAgent takes this long to conceal items again (they fade out).
  private static let concealSettle: Duration = .milliseconds(700)

  /// Restores the restriction and, once the concealed items are gone again,
  /// uncovers the menu bar.
  private func scheduleRestore() {
    restoring?.cancel()
    restoring = Task {
      if isLifted {
        isLifted = false
        liftedAt = nil
        await concealer.resume()
      }
      try? await Task.sleep(for: Self.concealSettle)
      guard !Task.isCancelled, isCovered else { return }
      isCovered = false
      curtain.lower()
      restoring = nil
      updateClockFrame()
    }
  }

  /// Notification Center's panel spans the display; its banners are small.
  static func isNotificationCenterOpen() -> Bool {
    guard
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundleID).first?
        .processIdentifier,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    return list.contains { window in
      guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds)
      else { return false }
      return frame.height >= 400
    }
  }
}

/// Takes left clicks on the clock away from the system. It runs on a thread
/// of its own: it sees every click the person makes, which must not wait
/// for MyBar's main thread.
private final class ClockTap: @unchecked Sendable {
  private struct State {
    var clockFrame: CGRect?
    /// A click on the clock was taken; its button-up is still to come.
    var swallowing = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  /// Called with true when the button goes down on the clock, false when it
  /// comes up.
  private let onClick: @Sendable (Bool) -> Void
  private var tap: CFMachPort?

  init(onClick: @escaping @Sendable (Bool) -> Void) {
    self.onClick = onClick
  }

  var clockFrame: CGRect? {
    get { state.withLock { $0.clockFrame } }
    set { state.withLock { $0.clockFrame = newValue } }
  }

  func isOnClock(_ point: CGPoint) -> Bool {
    clockFrame?.contains(point) == true
  }

  func start() -> Bool {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: clockCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }
    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    let thread = Thread {
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopRun()
    }
    thread.name = "MyBar clock"
    thread.qualityOfService = .userInteractive
    thread.start()
    return true
  }

  fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == InputShield.marker {
      return Unmanaged.passUnretained(event)
    }
    let location = event.location
    let take: Bool = state.withLock { state in
      switch type {
      case .leftMouseDown where state.clockFrame?.contains(location) == true:
        state.swallowing = true
        return true
      case .leftMouseUp where state.swallowing:
        state.swallowing = false
        return true
      default:
        return false
      }
    }
    guard take else { return Unmanaged.passUnretained(event) }
    // The clock is pressed once the button is up: MenuBarAgent ignores a
    // press made while the mouse button is still down.
    onClick(type == .leftMouseDown)
    return nil
  }
}

private func clockCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  return Unmanaged<ClockTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}

extension AgentScanner {
  struct Clock: @unchecked Sendable {
    let frame: CGRect
    let element: AXUIElement
  }

  /// The menu bar clock, asking MenuBarAgent alone.
  nonisolated static func clock() -> Clock? {
    guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleID).first else {
      return nil
    }
    let element = AXUIElementCreateApplication(agent.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.25)
    guard let bar: AXUIElement = AX.value(element, "AXExtrasMenuBar"),
      let children: [AXUIElement] = AX.value(bar, kAXChildrenAttribute)
    else { return nil }
    for child in children {
      guard let inner: [AXUIElement] = AX.value(child, kAXChildrenAttribute), let item = inner.first,
        AX.value(item, kAXIdentifierAttribute) == NotificationCenterBridge.clockIdentifier,
        let frame = AX.frame(of: child)
      else { continue }
      return Clock(frame: frame, element: item)
    }
    return nil
  }
}

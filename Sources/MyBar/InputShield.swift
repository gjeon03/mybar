import AppKit

/// Keeps the person's own clicks from interfering while MyBar drives the
/// pointer. A synthesized drag breaks if a real click lands in the middle of
/// it, so while the shield is up, physical mouse buttons are held back
/// (MyBar's own events carry a marker and pass). Movement is held back only
/// while a drag is under way (a tenth of a second or so), as it breaks
/// drags too.
/// A click that was held back is reported, so the caller can act on it
/// afterwards. The shield never stays up longer than `maximumHold`.
@MainActor
final class InputShield {
  /// Stamped on every event MyBar posts (`eventSourceUserData`).
  nonisolated static let marker: Int64 = 0x4D79_4261_72

  /// Called with the location (window-server coordinates) of each click that
  /// was held back.
  var onHeldClick: ((CGPoint) -> Void)?

  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var depth = 0
  fileprivate var heldClicks: [CGPoint] = []

  /// However long MyBar is busy, the person gets their mouse back after this.
  static let maximumHold: Duration = .seconds(5)
  private var watchdog: Task<Void, Never>?

  /// Raises the shield. Calls nest; it stays up until the matching number of
  /// `lower()` calls, or until `maximumHold` has passed.
  func raise() {
    depth += 1
    guard depth == 1 else { return }
    if tap == nil { install() }
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    watchdog?.cancel()
    watchdog = Task { [weak self] in
      try? await Task.sleep(for: Self.maximumHold)
      guard !Task.isCancelled, let self, self.depth > 0 else { return }
      Log.app.error("input shield held too long; releasing it")
      self.depth = 1
      self.lower()
    }
  }

  func lower() {
    guard depth > 0 else { return }
    depth -= 1
    guard depth == 0 else { return }
    watchdog?.cancel()
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    let clicks = heldClicks
    heldClicks = []
    for point in clicks { onHeldClick?(point) }
  }

  private func install() {
    let types: [CGEventType] = [
      .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
      .otherMouseDown, .otherMouseUp, .otherMouseDragged,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: shieldCallback, userInfo: context)
    else {
      Log.app.error("could not install the input shield")
      return
    }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: false)
    self.tap = tap
    self.source = source
  }

  fileprivate func reenable() {
    if depth > 0, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
  }
}

private func shieldCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let shield = Unmanaged<InputShield>.fromOpaque(userInfo).takeUnretainedValue()
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    MainActor.assumeIsolated { shield.reenable() }
    return Unmanaged.passUnretained(event)
  }
  if event.getIntegerValueField(.eventSourceUserData) == InputShield.marker {
    return Unmanaged.passUnretained(event)
  }
  if type == .mouseMoved {
    return EventDriver.isDriving ? nil : Unmanaged.passUnretained(event)
  }
  if type == .leftMouseUp {
    let location = event.location
    MainActor.assumeIsolated { shield.heldClicks.append(location) }
  }
  return nil
}

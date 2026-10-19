import AppKit
import os

/// Synthesizes mouse input against the menu bar.
///
/// Status items are rearranged by command-dragging them, exactly as a person
/// would. The cursor is returned to where it was afterwards.
enum EventDriver {
  private static let source = CGEventSource(stateID: .combinedSessionState)

  /// Pacing of a synthesized drag. The menu bar ignores drags that are too
  /// abrupt, but long, straight drags tolerate a brisker pace.
  struct DragPace: Sendable {
    var hoverBeforePress: useconds_t = 30_000
    var holdBeforeMoving: useconds_t = 60_000
    var steps = 25
    var stepDelay: useconds_t = 16_000
    var holdBeforeRelease: useconds_t = 150_000
    var waitAfterRelease: useconds_t = 40_000
    /// Longest distance covered by one step; long drags take more steps.
    var maxStepLength: CGFloat = .infinity

    static let standard = DragPace()
    static let quick = DragPace(
      hoverBeforePress: 15_000, holdBeforeMoving: 40_000, steps: 10, stepDelay: 7_000, holdBeforeRelease: 60_000)
    /// About 0.15 s; measured to be taken reliably on macOS 26. The pause
    /// before letting go gives the menu bar time to open a gap where the item
    /// is dropped, or it lands next to it. Retried at `quick` when ignored.
    static let swift = DragPace(
      hoverBeforePress: 8_000, holdBeforeMoving: 25_000, steps: 5, stepDelay: 5_000, holdBeforeRelease: 60_000,
      waitAfterRelease: 5_000, maxStepLength: 30)
    /// Like `swift` with a shorter pause before letting go, enough for drops
    /// among items of one section (sliding), where no divider is crossed.
    static let slide = DragPace(
      hoverBeforePress: 8_000, holdBeforeMoving: 25_000, steps: 5, stepDelay: 5_000, holdBeforeRelease: 25_000,
      waitAfterRelease: 5_000, maxStepLength: 30)
  }

  /// Shortest horizontal travel of a drag the menu bar reliably takes.
  private static let minimumTravel: CGFloat = 30

  /// Runs `commandDrag` off the main thread so the UI stays responsive.
  static func commandDragAsync(from start: CGPoint, to end: CGPoint, pace: DragPace = .standard) async {
    await Task.detached(priority: .userInitiated) { commandDrag(from: start, to: end, pace: pace) }.value
  }

  static func commandDrag(from start: CGPoint, to end: CGPoint, pace: DragPace = .standard) {
    beginDriving()
    defer { endDriving() }
    let saved = currentCursorLocation()
    // Detach the physical mouse so the person's own movements can't disturb the drag.
    CGAssociateMouseAndMouseCursorPosition(0)
    defer { CGAssociateMouseAndMouseCursorPosition(1) }
    post(.mouseMoved, at: start, flags: [])
    usleep(pace.hoverBeforePress)
    post(.leftMouseDown, at: start, flags: .maskCommand)
    usleep(pace.holdBeforeMoving)
    // The menu bar ignores a drag that travels only a few points (dropping an
    // item next to its neighbor can be one): go past the drop point and back.
    var waypoints = [end]
    if abs(end.x - start.x) < minimumTravel {
      let direction: CGFloat = end.x < start.x ? -1 : 1
      waypoints.insert(CGPoint(x: end.x + direction * minimumTravel, y: end.y), at: 0)
    }
    var from = start
    for waypoint in waypoints {
      let distance = hypot(waypoint.x - from.x, waypoint.y - from.y)
      let steps = max(pace.steps, Int((distance / pace.maxStepLength).rounded(.up)))
      for step in 1...steps {
        let progress = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(
          x: from.x + (waypoint.x - from.x) * progress, y: from.y + (waypoint.y - from.y) * progress)
        post(.leftMouseDragged, at: point, flags: .maskCommand)
        usleep(pace.stepDelay)
      }
      from = waypoint
    }
    usleep(pace.holdBeforeRelease)
    post(.leftMouseUp, at: end, flags: .maskCommand)
    releaseCommand()
    usleep(pace.waitAfterRelease)
    warpBack(to: saved)
  }

  static func click(at point: CGPoint) {
    beginDriving()
    defer { endDriving() }
    let saved = currentCursorLocation()
    CGAssociateMouseAndMouseCursorPosition(0)
    defer { CGAssociateMouseAndMouseCursorPosition(1) }
    post(.mouseMoved, at: point, flags: [])
    usleep(12_000)
    post(.leftMouseDown, at: point, flags: [])
    usleep(25_000)
    post(.leftMouseUp, at: point, flags: [])
    usleep(10_000)
    warpBack(to: saved)
  }

  /// Puts the cursor back, and waits until the window server has it there:
  /// the move lands a few milliseconds later, and a pointer shown before then
  /// flashes up where MyBar left it.
  private static func warpBack(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    for _ in 0..<25 {
      let now = currentCursorLocation()
      if abs(now.x - point.x) < 1, abs(now.y - point.y) < 1 { return }
      usleep(2_000)
    }
  }

  /// Mouse events posted with the Command flag leave the Command key marked
  /// as held down system-wide, which turns the person's next clicks into
  /// Command-clicks (a Command-click on a menu bar item starts a drag instead
  /// of opening it). Let go of it, as a person would after dragging.
  private static func releaseCommand() {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return }
    event.flags = []
    event.setIntegerValueField(.eventSourceUserData, value: InputShield.marker)
    event.post(tap: .cghidEventTap)
  }

  private static func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { return }
    event.flags = flags
    // A real press counts clicks; some apps ignore a press with a count of 0.
    if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
    // Lets the input shield tell MyBar's events from the person's.
    event.setIntegerValueField(.eventSourceUserData, value: InputShield.marker)
    event.post(tap: .cghidEventTap)
  }

  /// Whether MyBar is driving the cursor, and a count bumped whenever that changes.
  private static let driving = OSAllocatedUnfairLock(initialState: (active: 0, changes: 0))

  private static func beginDriving() {
    driving.withLock {
      $0.active += 1; $0.changes += 1
    }
  }

  private static func endDriving() {
    driving.withLock {
      $0.active -= 1; $0.changes += 1
    }
  }

  /// Whether MyBar is in the middle of a drag or click.
  static var isDriving: Bool { driving.withLock { $0.active > 0 } }

  /// Where the person's cursor is (window-server coordinates), or nil while
  /// MyBar has taken it somewhere else.
  static func personsCursorLocation() -> CGPoint? {
    let before = driving.withLock { $0 }
    guard before.active == 0 else { return nil }
    let location = currentCursorLocation()
    let after = driving.withLock { $0 }
    return after.changes == before.changes ? location : nil
  }

  private static func currentCursorLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
  }
}

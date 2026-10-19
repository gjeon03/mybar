// Moves the mouse a little every 15 ms, like a person resting a hand on it. usage: jiggle <seconds>
import CoreGraphics
import Foundation
let end = Date().addingTimeInterval(Double(CommandLine.arguments[1])!)
let src = CGEventSource(stateID: .hidSystemState)
var d: CGFloat = 1
while Date() < end {
  let p = CGEvent(source: nil)!.location
  let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: p.x + d, y: p.y), mouseButton: .left)!
  e.setDoubleValueField(.mouseEventDeltaX, value: Double(d))
  e.post(tap: .cghidEventTap)
  d = -d
  usleep(15_000)
}

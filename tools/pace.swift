// usage: pace <windowID> <dropX> <hover> <hold> <steps> <step> <release> <after>   (ms)
import AppKit
func frame(_ id: CGWindowID) -> CGRect? {
  let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
  guard let b = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
  return CGRect(dictionaryRepresentation: b)
}
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let id = CGWindowID(a[0]), dropX = a[1]
let (hover, hold, steps, step, release, after) = (a[2], a[3], Int(a[4]), a[5], a[6], a[7])
let src = CGEventSource(stateID: .combinedSessionState)
func post(_ t: CGEventType, _ p: CGPoint, _ f: CGEventFlags) {
  let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
  e.flags = f; e.post(tap: .cghidEventTap)
}
func ms(_ v: Double) { if v > 0 { usleep(useconds_t(v * 1000)) } }
let f0 = frame(id)!
let saved = CGEvent(source: nil)!.location
let t0 = Date()
CGAssociateMouseAndMouseCursorPosition(0)
let start = CGPoint(x: f0.midX, y: f0.midY), end = CGPoint(x: dropX, y: f0.midY)
post(.mouseMoved, start, []); ms(hover)
post(.leftMouseDown, start, .maskCommand); ms(hold)
for s in 1...steps {
  let t = Double(s) / Double(steps)
  post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y), .maskCommand); ms(step)
}
ms(release)
post(.leftMouseUp, end, .maskCommand); ms(after)
CGWarpMouseCursorPosition(saved)
CGAssociateMouseAndMouseCursorPosition(1)
let posted = Date().timeIntervalSince(t0)
var moved = -1.0
for i in 0..<60 { usleep(5000); if frame(id)!.minX != f0.minX { moved = Date().timeIntervalSince(t0); break }; _ = i }
print(String(format: "from %.0f -> %.0f  posted %.0f ms, moved at %.0f ms", f0.minX, frame(id)!.minX, posted*1000, moved*1000))

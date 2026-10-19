// Lists status-item windows (layer 25) right of x=1200 with frames, on-screen flag and alpha.
import AppKit
var n: UInt32 = 0; var ids = [CGDirectDisplayID](repeating: 0, count: 8)
CGGetActiveDisplayList(8, &ids, &n)
for d in ids.prefix(Int(n)) { print(d, CGDisplayBounds(d), CGDisplayIsBuiltin(d)) }
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in info where (w[kCGWindowLayer as String] as? Int) == 25 {
  let r = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! NSDictionary)!
  if r.minX > 1200 { print(w[kCGWindowNumber as String]!, w[kCGWindowName as String] ?? "", r, w[kCGWindowIsOnscreen as String] ?? "-", w[kCGWindowAlpha as String]!) }
}

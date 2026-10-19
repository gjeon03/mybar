// Logs real cursor visibility/position and MyBar's stand-in window frame. usage: curwatch <seconds>
import AppKit
typealias Vis = @convention(c) () -> Int32
let isVisible = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "CGCursorIsVisible")!, to: Vis.self)
let end = Date().addingTimeInterval(Double(CommandLine.arguments[1])!)
let t0 = Date()
var last = ""
while Date() < end {
  let vis = isVisible()
  let loc = CGEvent(source: nil)!.location
  var stand = "-"
  for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] {
    if (w[kCGWindowOwnerName as String] as? String) == "MyBar", (w[kCGWindowLayer as String] as? Int ?? 0) > 1000 {
      let b = CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! NSDictionary)!
      stand = "\(Int(b.minX)),\(Int(b.minY))"
    }
  }
  let line = "vis=\(vis) cur=\(Int(loc.x)),\(Int(loc.y)) stand=\(stand)"
  if line != last { print(String(format: "%5.0f", Date().timeIntervalSince(t0) * 1000), line); last = line }
  usleep(4000)
}

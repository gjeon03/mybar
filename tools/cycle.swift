// Drives MyBar like a person: click the control item, click a bar entry, repeat.
// usage: cycle <rounds> [settleMs]
import AppKit

let rounds = Int(CommandLine.arguments[1])!
let settle = UInt32(CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1500)
let src = CGEventSource(stateID: .hidSystemState)
func click(_ p: CGPoint) {
  for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(30_000)
  }
}
func windows() -> [[String: Any]] { CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] }
func frame(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! NSDictionary)! }
func control() -> CGRect? {
  // macOS 26: the icon has a window titled with its autosave name.
  let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
  if let window = all.first(where: { ($0[kCGWindowName as String] as? String) == "MyBarControl" }) {
    return frame(window)
  }
  // macOS 27: no item windows; ask Accessibility.
  guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.gimbap.mybar").first else {
    return nil
  }
  let element = AXUIElementCreateApplication(app.processIdentifier)
  var bar: CFTypeRef?
  AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar)
  var kids: CFTypeRef?
  if let bar { AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) }
  for kid in (kids as? [AXUIElement]) ?? [] {
    var id: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
    AXUIElementCopyAttributeValue(kid, kAXIdentifierAttribute as CFString, &id)
    guard (id as? String) == "MyBarControl" else { continue }
    AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &pos)
    AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &size)
    var p = CGPoint.zero, s = CGSize.zero
    if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
    if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
  }
  return nil
}
let mybar = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.gimbap.mybar").first!
func entries() -> [(String, CGRect)] {
  let app = AXUIElementCreateApplication(mybar.processIdentifier)
  var ws: CFTypeRef?
  AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws)
  var out: [(String, CGRect)] = []
  func walk(_ e: AXUIElement) {
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
    if (role as? String) == "AXButton" {
      var pos: CFTypeRef?, size: CFTypeRef?, title: CFTypeRef?, desc: CFTypeRef?
      AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos)
      AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size)
      AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
      AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &desc)
      var p = CGPoint.zero, s = CGSize.zero
      if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
      if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
      let name = ((title as? String) ?? "") + "|" + ((desc as? String) ?? "")
      if s.width > 0 { out.append((name, CGRect(origin: p, size: s))) }
    }
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
    for k in (kids as? [AXUIElement]) ?? [] { walk(k) }
  }
  for w in (ws as? [AXUIElement]) ?? [] { walk(w) }
  return out
}
/// Menus and popovers of other apps currently on screen.
func popups() -> [Int] {
  windows().compactMap { w in
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    // Menus (101), popovers and panels (1–24), and panels some apps put at the
    // status level (25, e.g. PokeTokenBar) — but not the status items themselves.
    let height = (w[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0
    guard owner != "MyBar", owner != "Control Center",
      layer == 101 || (layer > 0 && layer < 25) || (layer == 25 && height > 60)
    else { return nil }
    return w[kCGWindowNumber as String] as? Int
  }
}
let home = CGEvent(source: nil)!.location
let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
for round in 1...rounds {
  guard let c = control() else { print("no control"); break }
  click(CGPoint(x: c.midX, y: c.midY))
  var list: [(String, CGRect)] = []
  for _ in 0..<40 { usleep(50_000); list = entries(); if !list.isEmpty { break } }
  if list.isEmpty { print(f.string(from: Date()), "round \(round): BAR DID NOT OPEN"); continue }
  let choices = list.filter { !$0.0.lowercased().contains("clipboard") }
  let pick = choices.randomElement()!
  print(f.string(from: Date()), "round \(round): \(list.count) entries, click \(pick.0)")
  let before = Set(popups())
  let clickedAt = Date()
  click(CGPoint(x: pick.1.midX, y: pick.1.midY))
  var shown = false
  while Date().timeIntervalSince(clickedAt) < 4 {
    usleep(30_000)
    if !Set(popups()).subtracting(before).isEmpty { shown = true; break }
  }
  let took = Int(Date().timeIntervalSince(clickedAt) * 1000)
  print("   ", shown ? "SHOWN after \(took) ms" : "NOTHING SHOWN within 4 s")
  usleep(settle * 1000)
}
CGWarpMouseCursorPosition(home)

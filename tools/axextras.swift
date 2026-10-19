// Lists every app's menu bar extras as Accessibility reports them (frame, identifier, title, actions).
import AppKit
print("AX trusted:", AXIsProcessTrusted())
for app in NSWorkspace.shared.runningApplications {
  let el = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(el, 0.3)
  var bar: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar else { continue }
  var kids: CFTypeRef?
  AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
  for k in (kids as? [AXUIElement]) ?? [] {
    func value(_ name: String) -> CFTypeRef? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(k, name as CFString, &v); return v }
    var p = CGPoint.zero, s = CGSize.zero
    if let pos = value(kAXPositionAttribute) { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
    if let size = value(kAXSizeAttribute) { AXValueGetValue(size as! AXValue, .cgSize, &s) }
    var names: CFArray?
    AXUIElementCopyActionNames(k, &names)
    print(app.bundleIdentifier ?? "?", Int(p.x), Int(p.y), Int(s.width), "id=\(value(kAXIdentifierAttribute) as? String ?? "-")",
      "title=\(value(kAXTitleAttribute) as? String ?? "-")", "desc=\(value(kAXDescriptionAttribute) as? String ?? "-")",
      "actions=\((names as? [String]) ?? [])")
  }
}

// Presses the first status item of an app through Accessibility. usage: axpress <bundle-id>
import AppKit
let bundle = CommandLine.arguments[1]
let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first!
let el = AXUIElementCreateApplication(app.processIdentifier)
var bar: CFTypeRef?
AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar)
var kids: CFTypeRef?
AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
let item = (kids as! [AXUIElement])[0]
var names: CFArray?
AXUIElementCopyActionNames(item, &names)
print("actions", names as Any)
print("press", AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)

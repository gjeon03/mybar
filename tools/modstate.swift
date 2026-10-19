// Prints the modifier state of the HID and session event sources, and whether
// the left/right Command keys are marked down (stuck Command makes clicks Command-clicks).
import CoreGraphics
for (n, s) in [("hid", CGEventSourceStateID.hidSystemState), ("combined", .combinedSessionState)] {
  print(n, String(CGEventSource.flagsState(s).rawValue, radix: 16), "cmdKeyDown", CGEventSource.keyState(s, key: 0x37), CGEventSource.keyState(s, key: 0x36))
}

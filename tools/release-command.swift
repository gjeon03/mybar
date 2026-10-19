// Posts a Command key-up at the HID tap: clears a Command key left marked down.
import CoreGraphics
let src = CGEventSource(stateID: .hidSystemState)
let up = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)!
up.flags = []
up.post(tap: .cghidEventTap)

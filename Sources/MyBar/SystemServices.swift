import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A single global shortcut (⌥⌘B) that toggles hidden items.
@MainActor
final class Hotkey {
  var action: (() -> Void)?
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?

  static let displayString = "⌥⌘B"

  func setEnabled(_ enabled: Bool) {
    if enabled { register() } else { unregister() }
  }

  private func register() {
    guard hotKeyRef == nil else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let userData = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { hotkey.action?() }
        return noErr
      }, 1, &spec, userData, &handlerRef)
    let id = EventHotKeyID(signature: OSType(0x4D59_4252), id: 1)
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    if status != noErr {
      Log.app.error("hotkey registration failed: \(status)")
    }
  }

  private func unregister() {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
    hotKeyRef = nil
    handlerRef = nil
  }
}

enum LaunchAtLogin {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static func set(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}

enum Permissions {
  static var accessibility: Bool { AXIsProcessTrusted() }
  static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

  static func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func requestScreenRecording() {
    if !CGRequestScreenCaptureAccess() {
      openPrivacyPane("Privacy_ScreenCapture")
    }
  }

  /// Why the running copy can't keep permissions, if it's not in a place
  /// macOS recognises: opened straight from the disk image, or moved aside by
  /// Gatekeeper ("App Translocation") because it was never put in Applications.
  static var locationProblem: String? {
    let path = Bundle.main.bundlePath
    if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
      return "MyBar is running from the disk image or a temporary copy, so permissions you grant won't stick. "
        + "Quit MyBar, drag it into the Applications folder, eject the disk image, and open it from Applications."
    }
    return nil
  }

  /// Clears MyBar's entries in Privacy & Security — toggles granted to an
  /// earlier copy look on but don't apply to this one — and reopens MyBar so
  /// macOS asks again.
  static func resetAndRelaunch() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    for service in ["Accessibility", "ScreenCapture"] {
      let reset = Process()
      reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
      reset.arguments = ["reset", service, bundleID]
      try? reset.run()
      reset.waitUntilExit()
    }
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
    relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? relaunch.run()
    NSApp.terminate(nil)
  }

  static func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }
}

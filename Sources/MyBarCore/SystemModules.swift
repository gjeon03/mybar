/// Apple's own menu bar items that Control Center draws (macOS 27+).
///
/// They belong to Control Center, so hiding the "app" would hide them all.
/// Each one is a Control Center module instead, shown in the menu bar or not
/// according to a per-host preference of Control Center (the value System
/// Settings › Menu Bar writes); Control Center follows a change at once.
public enum SystemModules {
  /// The preference domain, read and written for the current host.
  public static let domain = "com.apple.controlcenter"
  /// The bundle identifier in the keys of Control Center's items.
  public static let bundleID = "com.apple.controlcenter"
  /// Preference value that keeps a module out of the menu bar.
  public static let hiddenValue = 8
  /// Value to show a module with when its original one is unknown.
  public static let shownValue = 2

  /// Menu bar extra identifiers and the preference keys of their modules.
  /// The clock and Control Center itself always stay.
  static let preferenceKeys: [String: String] = [
    "com.apple.menuextra.wifi": "WiFi",
    "com.apple.menuextra.sound": "Sound",
    "com.apple.menuextra.display": "Display",
    "com.apple.menuextra.battery": "Battery",
    "com.apple.menuextra.bluetooth": "Bluetooth",
    "com.apple.menuextra.airdrop": "AirDrop",
    "com.apple.menuextra.focusmode": "FocusModes",
    "com.apple.menuextra.nowplaying": "NowPlaying",
    "com.apple.menuextra.screenmirroring": "ScreenMirroring",
    "com.apple.menuextra.siri": "Siri",
    "com.apple.menuextra.voicecontrol": "VoiceControl",
    "com.apple.menuextra.keyboardbrightness": "KeyboardBrightness",
    "com.apple.menuextra.accessibility": "AccessibilityShortcuts",
    "com.apple.menuextra.hearing": "Hearing",
    "com.apple.menuextra.userswitcher": "UserSwitcher",
  ]

  /// Names to show for modules that are hidden (and so not around to ask).
  static let displayNames: [String: String] = [
    "WiFi": "Wi‑Fi", "Sound": "Sound", "Display": "Display", "Battery": "Battery", "Bluetooth": "Bluetooth",
    "AirDrop": "AirDrop", "FocusModes": "Focus", "NowPlaying": "Now Playing", "ScreenMirroring": "Screen Mirroring",
    "Siri": "Siri", "VoiceControl": "Voice Control", "KeyboardBrightness": "Keyboard Brightness",
    "AccessibilityShortcuts": "Accessibility Shortcuts", "Hearing": "Hearing", "UserSwitcher": "Fast User Switching",
  ]

  public static func displayName(for key: ItemKey) -> String? {
    preferenceKey(for: key).flatMap { displayNames[$0] }
  }

  /// Every hideable item's identifier with its module's preference key.
  public static var allPreferenceKeys: [(identifier: String, preferenceKey: String)] {
    preferenceKeys.map { ($0.key, $0.value) }.sorted { $0.identifier < $1.identifier }
  }

  /// The preference key of the module behind the item with `key`, or nil
  /// when the item isn't a Control Center module MyBar can hide.
  public static func preferenceKey(for key: ItemKey) -> String? {
    let parts = key.rawValue.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0] == bundleID else { return nil }
    let identifier = parts[1].split(separator: "#").first.map(String.init) ?? parts[1]
    return preferenceKeys[identifier]
  }

  /// Whether `key` is one of Control Center's items (hideable or not).
  public static func isSystemItem(_ key: ItemKey) -> Bool {
    key.rawValue.hasPrefix(bundleID + "/")
  }

  /// Whether a stored preference value means the module is in the menu bar.
  /// 8 hides it (24 after "Remove from Menu Bar"); 2 shows it, 18 shows it
  /// when it applies.
  public static func isShown(_ value: Int) -> Bool {
    value & 8 == 0
  }
}

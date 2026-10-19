/// Which apps' menu bar items MenuBarAgent shows (macOS 27+).
///
/// MenuBarAgent can be told to show only the items of an allowed list of
/// apps; the rest are taken out of the menu bar altogether (no chevron, no
/// gap). MyBar allows every running app except the concealed ones, and
/// briefly allows a concealed one again to open it.
public enum Concealment {
  /// The bundle identifier in an item key (`bundle/identifier[#n]`).
  public static func bundleID(of key: ItemKey) -> String {
    String(key.rawValue.split(separator: "/", maxSplits: 1).first ?? "")
  }

  /// Apps to allow: every running app except the concealed ones that aren't
  /// being revealed. `revealAll` lifts concealment without forgetting it.
  public static func allowedBundles(
    running: [String], concealed: [String: MenuBarSection], revealed: Set<String>, revealAll: Bool
  ) -> [String] {
    var seen: Set<String> = []
    return running.filter { bundle in
      guard seen.insert(bundle).inserted else { return false }
      return revealAll || revealed.contains(bundle) || concealed[bundle] == nil
    }
  }

  /// The section of an item with `key`, given what is concealed: apps by
  /// bundle identifier, Control Center modules by item key.
  public static func section(of key: ItemKey, concealed: [String: MenuBarSection]) -> MenuBarSection {
    concealed[key.rawValue] ?? concealed[bundleID(of: key)] ?? .visible
  }

  /// What `key` is concealed by in the concealed list: its own key for a
  /// Control Center module, its app's bundle identifier otherwise.
  public static func concealmentKey(of key: ItemKey) -> String {
    SystemModules.preferenceKey(for: key) != nil ? key.rawValue : bundleID(of: key)
  }

  /// Every system item MenuBarAgent knows (0 is the battery), all allowed.
  public static let allSystemItems = Array(0...8)
}

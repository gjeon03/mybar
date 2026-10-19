import Foundation

/// A named set of menu bar items shown together behind one icon.
public struct ItemGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var symbolName: String
  public var memberKeys: [ItemKey]

  public init(id: UUID = UUID(), name: String, symbolName: String = "square.grid.2x2", memberKeys: [ItemKey] = []) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.memberKeys = memberKeys
  }

  /// Autosave name of the group's own status item.
  public var autosaveName: String { "MyBarGroup-\(id.uuidString)" }
}

/// How hidden items are revealed.
public enum RevealStyle: String, Codable, CaseIterable, Sendable, Identifiable {
  /// Show item images in a floating bar below the menu bar (notch friendly).
  case bar
  /// Expand the hidden section inside the menu bar itself.
  case menuBar

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .bar: "MyBar Bar (below the menu bar)"
    case .menuBar: "In the menu bar"
    }
  }
}

public struct MyBarSettings: Codable, Equatable, Sendable {
  public var revealStyle: RevealStyle = .bar
  /// Seconds before an expanded menu bar collapses again.
  public var autoRehideDelay: Double = 10
  /// Seconds a hidden item stays in the menu bar after it was activated.
  public var activationShowDuration: Double = 5
  public var optionClickShowsAlwaysHidden = true
  public var hotkeyEnabled = true
  public var hideGroupMembersFromBar = true
  public var groups: [ItemGroup] = []
  public var hasCompletedOnboarding = false
  /// On macOS 27+, the apps whose menu bar items are concealed, by bundle
  /// identifier, with the section they belong to (Hidden or Always Hidden).
  /// There, sections are kept by MyBar rather than read from positions.
  public var concealedApps: [String: MenuBarSection] = [:]
  /// What MyBar's own menu bar icon looks like.
  public var controlIcon: ControlIcon = .default

  public init() {}

  public init(from decoder: Decoder) throws {
    let defaults = MyBarSettings()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    revealStyle = try c.decodeIfPresent(RevealStyle.self, forKey: .revealStyle) ?? defaults.revealStyle
    autoRehideDelay = try c.decodeIfPresent(Double.self, forKey: .autoRehideDelay) ?? defaults.autoRehideDelay
    activationShowDuration =
      try c.decodeIfPresent(Double.self, forKey: .activationShowDuration) ?? defaults.activationShowDuration
    optionClickShowsAlwaysHidden =
      try c.decodeIfPresent(Bool.self, forKey: .optionClickShowsAlwaysHidden)
      ?? defaults.optionClickShowsAlwaysHidden
    hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? defaults.hotkeyEnabled
    hideGroupMembersFromBar =
      try c.decodeIfPresent(Bool.self, forKey: .hideGroupMembersFromBar) ?? defaults.hideGroupMembersFromBar
    groups = try c.decodeIfPresent([ItemGroup].self, forKey: .groups) ?? defaults.groups
    hasCompletedOnboarding =
      try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? defaults.hasCompletedOnboarding
    concealedApps =
      try c.decodeIfPresent([String: MenuBarSection].self, forKey: .concealedApps) ?? defaults.concealedApps
    controlIcon = (try? c.decodeIfPresent(ControlIcon.self, forKey: .controlIcon)) ?? defaults.controlIcon
  }

  /// The group an item belongs to, if any.
  public func group(containing key: ItemKey) -> ItemGroup? {
    groups.first { $0.memberKeys.contains(key) }
  }

  /// Adds `key` to the group with `groupID`, removing it from any other group.
  public mutating func assign(_ key: ItemKey, toGroup groupID: UUID?) {
    for index in groups.indices {
      groups[index].memberKeys.removeAll { $0 == key }
    }
    guard let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
    groups[index].memberKeys.append(key)
  }
}

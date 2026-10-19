import CoreGraphics
import Foundation

/// A status-item window as reported by the window server.
///
/// On macOS 26 every status-item window is owned by Control Center, and the
/// window title carries the item's autosave name (for example `Item-0`).
public struct WindowInfo: Equatable, Sendable {
  public let windowID: CGWindowID
  public let frame: CGRect
  public let title: String
  public let ownerPID: pid_t
  public let ownerName: String
  public let isOnScreen: Bool

  public init(
    windowID: CGWindowID, frame: CGRect, title: String, ownerPID: pid_t, ownerName: String,
    isOnScreen: Bool
  ) {
    self.windowID = windowID
    self.frame = frame
    self.title = title
    self.ownerPID = ownerPID
    self.ownerName = ownerName
    self.isOnScreen = isOnScreen
  }
}

/// A menu bar extra as reported by an application's Accessibility tree.
public struct AXItemInfo: Equatable, Sendable, Codable {
  public let bundleID: String
  public let pid: pid_t
  public let appName: String
  public let frame: CGRect
  public let identifier: String?
  public let title: String?
  public let label: String?

  public init(
    bundleID: String, pid: pid_t, appName: String, frame: CGRect, identifier: String?,
    title: String?, label: String?
  ) {
    self.bundleID = bundleID
    self.pid = pid
    self.appName = appName
    self.frame = frame
    self.identifier = identifier
    self.title = title
    self.label = label
  }

  /// A copy of this item with a different frame.
  public func with(frame: CGRect) -> AXItemInfo {
    AXItemInfo(
      bundleID: bundleID, pid: pid, appName: appName, frame: frame, identifier: identifier, title: title, label: label)
  }
}

/// Stable identity of a menu bar item across launches and rescans.
public struct ItemKey: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }
}

/// One menu bar item: its window plus the application that owns it.
public struct MenuBarItem: Equatable, Sendable, Identifiable {
  public let window: WindowInfo
  public let owner: AXItemInfo?
  public let key: ItemKey

  public var id: CGWindowID { window.windowID }
  public var frame: CGRect { window.frame }
  public var bundleID: String? { owner?.bundleID }

  public init(window: WindowInfo, owner: AXItemInfo?, key: ItemKey) {
    self.window = window
    self.owner = owner
    self.key = key
  }

  /// A short human-readable name, preferring what the item says about itself.
  public var displayName: String {
    guard let owner else { return window.title.isEmpty ? "Unknown item" : window.title }
    if let label = owner.label?.nonEmpty, owner.bundleID.hasPrefix("com.apple.") {
      return Self.firstClause(of: label)
    }
    if let title = owner.title?.nonEmpty, title.count <= 24 {
      return "\(owner.appName) — \(title)"
    }
    return owner.appName
  }

  static func firstClause(of label: String) -> String {
    label.split(separator: ",", maxSplits: 1).first.map(String.init) ?? label
  }
}

extension String {
  var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

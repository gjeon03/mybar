import AppKit
import MyBarCore

/// One status item per group. Clicking it shows the group's members.
@MainActor
final class GroupItems {
  var onClick: ((UUID, NSStatusItem, NSEvent) -> Void)?
  private var items: [UUID: NSStatusItem] = [:]

  /// Creates, updates and removes group items. Returns the autosave names of
  /// items created by this call.
  @discardableResult
  func sync(_ groups: [ItemGroup]) -> [String] {
    var created: [String] = []
    let ids = Set(groups.map(\.id))
    for (id, item) in items where !ids.contains(id) {
      // Forget the position macOS saved, so a deleted group leaves nothing behind.
      let name = item.autosaveName
      NSStatusBar.system.removeStatusItem(item)
      items[id] = nil
      if let name {
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
      }
    }
    for group in groups {
      let item: NSStatusItem
      if let existing = items[group.id] {
        item = existing
      } else {
        StatusItems.seedPosition(StatusItems.groupPosition, for: group.autosaveName)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = group.autosaveName
        item.isVisible = true
        items[group.id] = item
        created.append(group.autosaveName)
        configure(item, groupID: group.id)
      }
      update(item, with: group)
    }
    return created
  }

  func item(for id: UUID) -> NSStatusItem? { items[id] }

  private func configure(_ item: NSStatusItem, groupID: UUID) {
    guard let button = item.button else { return }
    button.setAccessibilityIdentifier(OwnItemName.groupPrefix + groupID.uuidString)
    button.target = self
    button.action = #selector(clicked(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    button.identifier = NSUserInterfaceItemIdentifier(groupID.uuidString)
  }

  private func update(_ item: NSStatusItem, with group: ItemGroup) {
    let image =
      NSImage(systemSymbolName: group.symbolName, accessibilityDescription: group.name)
      ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: group.name)
    image?.isTemplate = true
    item.button?.image = image
    item.button?.toolTip = group.name
    item.button?.setAccessibilityLabel(group.name)
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
      let item = items[id], let event = NSApp.currentEvent
    else { return }
    onClick?(id, item, event)
  }
}

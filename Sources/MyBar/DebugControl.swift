#if DEBUG
  import AppKit
  import MyBarCore

  /// Debug-only remote control used by end-to-end checks. Commands arrive as
  /// distributed notifications named `dev.gimbap.mybar.debug` whose object is a
  /// space-separated command; results are written as JSON to the path in
  /// `MYBAR_DEBUG_OUT` (default `/tmp/mybar-debug.json`).
  ///
  ///     dump                       snapshot of items and sections
  ///     move <section> <key>...    move items to visible|hidden|alwaysHidden
  ///     reveal                     toggle hidden items (like clicking MyBar)
  ///     activate <key>             open an item as if clicked in the bar
  ///     group <name> <key>...      create a group with members
  ///     level <0|1|2>              hold the menu bar expanded (none|hidden|all)
  ///     style <bar|menuBar>        change how hidden items are revealed
  ///     ungroup <name>             delete the groups with this name
  ///     settings <tab>             open the settings window on a tab
  ///     diagnostics                copy the diagnostics report to the clipboard
  @MainActor
  final class DebugControl {
    private weak var model: AppModel?
    private let output = ProcessInfo.processInfo.environment["MYBAR_DEBUG_OUT"] ?? "/tmp/mybar-debug.json"

    init(model: AppModel) {
      self.model = model
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("dev.gimbap.mybar.debug"), object: nil, queue: .main
      ) { [weak self] note in
        let command = note.object as? String ?? ""
        MainActor.assumeIsolated { self?.handle(command) }
      }
    }

    private func handle(_ command: String) {
      guard let model else { return }
      let parts = command.split(separator: " ").map(String.init)
      guard let verb = parts.first else { return }
      Task {
        switch verb {
        case "dump":
          await model.refresh()
        case "move":
          guard parts.count >= 3, let section = MenuBarSection(rawValue: parts[1]) else { return }
          await model.moveAndWait(parts.dropFirst(2).map(ItemKey.init), to: section)
        case "reveal":
          model.toggleReveal(includeAlwaysHidden: false)
          await sleep(milliseconds: 1200)
        case "level":
          guard parts.count == 2, let raw = Int(parts[1]), let level = RevealLevel(rawValue: raw) else { return }
          model.statusItems.setLevel(level, for: "debug")
          await sleep(milliseconds: 600)
          await model.refresh()
        case "style":
          guard parts.count == 2, let style = RevealStyle(rawValue: parts[1]) else { return }
          model.settings.revealStyle = style
        case "ungroup":
          guard parts.count == 2 else { return }
          for group in model.settings.groups where group.name == parts[1] {
            model.deleteGroup(group.id)
          }
          await sleep(milliseconds: 800)
          await model.refresh()
        case "diagnostics":
          model.copyDiagnostics()
        case "settings":
          guard parts.count == 2, let tab = SettingsTab(rawValue: parts[1]) else { return }
          model.settingsTab = tab
          model.openSettings()
          await sleep(milliseconds: 800)
        case "activate":
          guard parts.count == 2 else { return }
          model.activate(ItemKey(parts[1]))
          await sleep(milliseconds: 2500)
        case "group":
          guard parts.count >= 2 else { return }
          let id = model.addGroup()
          if let index = model.settings.groups.firstIndex(where: { $0.id == id }) {
            model.settings.groups[index].name = parts[1]
          }
          for key in parts.dropFirst(2) {
            model.setMembership(ItemKey(key), group: id, isMember: true)
          }
          await sleep(milliseconds: 2500)
          await model.refresh()
        default:
          return
        }
        write(model: model, command: command)
      }
    }

    private func write(model: AppModel, command: String) {
      let snapshot = model.snapshot
      func describe(_ item: MenuBarItem) -> [String: Any] {
        [
          "key": item.key.rawValue, "name": item.displayName, "x": item.frame.minX, "width": item.frame.width,
          "onScreen": item.window.isOnScreen,
        ]
      }
      var sections: [String: Any] = [:]
      for (section, items) in snapshot.sections {
        sections[section.rawValue] = items.map(describe)
      }
      let payload: [String: Any] = [
        "command": command,
        "sections": sections,
        "hiddenDivider": snapshot.dividers.hidden.map { [$0.minX, $0.width] } ?? [],
        "alwaysHiddenDivider": snapshot.dividers.alwaysHidden.map { [$0.minX, $0.width] } ?? [],
        "control": snapshot.controlItem.map { [$0.frame.minX, $0.frame.width] } ?? [],
        "groups": snapshot.groupItems.mapValues { [$0.frame.minX, $0.frame.width] },
        "lastError": model.lastError ?? "",
        "revealLevel": model.statusItems.effectiveLevel.rawValue,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: output))
      }
    }
  }
#endif

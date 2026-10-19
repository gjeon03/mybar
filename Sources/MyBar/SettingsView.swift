import AppKit
import MyBarCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private weak var model: AppModel?
  private var window: NSWindow?

  init(model: AppModel) {
    self.model = model
  }

  func show() {
    guard let model else { return }
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
      window.title = "MyBar Settings"
      window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    model?.settingsWindowClosed()
  }
}

struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    TabView(selection: $model.settingsTab) {
      LayoutTab(model: model)
        .tabItem { Label("Layout", systemImage: "menubar.rectangle") }
        .tag(SettingsTab.layout)
      GroupsTab(model: model)
        .tabItem { Label("Groups", systemImage: "square.grid.2x2") }
        .tag(SettingsTab.groups)
      GeneralTab(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag(SettingsTab.general)
      PermissionsTab(model: model)
        .tabItem { Label("Permissions", systemImage: "lock.shield") }
        .tag(SettingsTab.permissions)
    }
    .padding(16)
    .frame(minWidth: 860, minHeight: 560)
  }
}

// MARK: - Layout

private struct LayoutTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Drag items between sections, or use the ⋯ menu on each item.")
          .foregroundStyle(.secondary)
        Spacer()
        if let message = model.busyMessage {
          ProgressView().controlSize(.small)
          Text(message).foregroundStyle(.secondary)
        }
        Button("Refresh") { Task { await model.refresh() } }
      }
      if !model.accessibilityGranted {
        PermissionBanner(model: model)
      } else if !model.hiddenAppleItems.isEmpty {
        HStack {
          Image(systemName: "apple.logo")
          Text("\(model.hiddenAppleItems.count) Apple items (Wi‑Fi, Battery, Sound…) are hidden.")
          Spacer()
          Button("Keep Apple Items Visible") { model.keepAppleItemsVisible() }
            .disabled(model.busyMessage != nil)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
      }
      HStack(alignment: .top, spacing: 12) {
        ForEach(MenuBarSection.allCases.reversed()) { section in
          SectionColumn(model: model, section: section)
        }
      }
      if let error = model.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }
  }
}

private struct SectionColumn: View {
  @ObservedObject var model: AppModel
  let section: MenuBarSection
  @State private var isTargeted = false

  private var caption: String {
    switch section {
    case .visible: "Always shown in the menu bar."
    case .hidden: "Shown when you click MyBar's icon."
    case .alwaysHidden: "Shown with ⌥-click or from Show All."
    }
  }

  var body: some View {
    let _ = model.imageVersion
    VStack(alignment: .leading, spacing: 6) {
      Text(section.title).font(.headline)
      Text(caption).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(model.items(in: section)) { item in
            if ItemMover.isFixed(item) {
              // macOS keeps these in place; offering a drag would only fail.
              ItemRow(model: model, item: item, section: section)
            } else {
              ItemRow(model: model, item: item, section: section)
                .draggable(item.key.rawValue)
            }
          }
          if model.items(in: section).isEmpty {
            Text("Drop items here")
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, minHeight: 60)
          }
        }
        .padding(6)
      }
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
      )
      .dropDestination(for: String.self) { keys, _ in
        model.move(keys.map(ItemKey.init), to: section)
        return true
      } isTargeted: {
        isTargeted = $0
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct ItemRow: View {
  @ObservedObject var model: AppModel
  let item: MenuBarItem
  let section: MenuBarSection

  var body: some View {
    HStack(spacing: 8) {
      ItemImageView(image: model.image(for: item), dark: model.images.prefersDarkBackground(for: [item.key]))
      VStack(alignment: .leading, spacing: 1) {
        Text(item.displayName).lineLimit(1)
        if ItemMover.isFixed(item) {
          Text("Fixed by macOS").font(.caption).foregroundStyle(.secondary)
        } else if let group = model.settings.group(containing: item.key) {
          Text("Group: \(group.name)").font(.caption).foregroundStyle(.secondary)
        } else if !item.window.isOnScreen && section == .visible {
          Text("Not shown by macOS").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 4)
      Menu {
        ForEach(MenuBarSection.allCases.filter { $0 != section }) { target in
          Button("Move to \(target.title)") { model.move([item.key], to: target) }
        }
        Divider()
        Menu("Group") {
          Button("None") { model.settings.assign(item.key, toGroup: nil) }
          ForEach(model.settings.groups) { group in
            Button(group.name) { model.setMembership(item.key, group: group.id, isMember: true) }
          }
        }
        Divider()
        Button("Open") { model.activate(item.key) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(ItemMover.isFixed(item))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
    .help(item.key.rawValue)
  }
}

private struct ItemImageView: View {
  let image: NSImage
  let dark: Bool

  var body: some View {
    Image(nsImage: image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: 40, height: 20)
      .padding(3)
      .background(RoundedRectangle(cornerRadius: 5).fill(dark ? Color.black.opacity(0.75) : Color.white))
  }
}

private struct PermissionBanner: View {
  @ObservedObject var model: AppModel

  var body: some View {
    HStack {
      Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
      Text("MyBar needs Accessibility access to identify and arrange menu bar items.")
      Spacer()
      Button("Open Permissions") { model.settingsTab = .permissions }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
  }
}

// MARK: - Groups

private struct GroupsTab: View {
  @ObservedObject var model: AppModel
  @State private var selection: UUID?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Groups").font(.headline)
        Text("Each group gets its own menu bar icon.").font(.caption).foregroundStyle(.secondary)
        VStack(spacing: 0) {
          if model.settings.groups.isEmpty {
            Text("No groups yet")
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            List(selection: $selection) {
              ForEach(model.settings.groups) { group in
                Label(group.name, systemImage: group.symbolName).tag(group.id)
              }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
          }
          Divider()
          HStack(spacing: 0) {
            Button {
              selection = model.addGroup()
            } label: {
              Image(systemName: "plus").frame(width: 28, height: 22)
            }
            .help("Add a group")
            Divider().frame(height: 16)
            Button {
              if let selection { model.deleteGroup(selection) }
              selection = model.settings.groups.first?.id
            } label: {
              Image(systemName: "minus").frame(width: 28, height: 22)
            }
            .help("Delete the selected group")
            .disabled(selection == nil)
            Spacer()
          }
          .buttonStyle(.borderless)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      .frame(width: 240)

      Group {
        if let id = selection, let index = model.settings.groups.firstIndex(where: { $0.id == id }) {
          GroupEditor(model: model, group: $model.settings.groups[index])
        } else {
          VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
            Text("Groups collect several items behind one icon.")
            Text("Create a group with +, pick its members, then hide them.").foregroundStyle(.secondary)
            Button("Create a Group") { selection = model.addGroup() }
              .padding(.top, 4)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear(perform: keepSelectionValid)
    .onChange(of: model.settings.groups.map(\.id)) { keepSelectionValid() }
  }

  /// Selects the first group when nothing (or a deleted group) is selected.
  private func keepSelectionValid() {
    let ids = model.settings.groups.map(\.id)
    if selection.map({ !ids.contains($0) }) ?? true {
      selection = ids.first
    }
  }
}

private struct GroupEditor: View {
  @ObservedObject var model: AppModel
  @Binding var group: ItemGroup

  private static let symbols = [
    "square.grid.2x2", "briefcase", "hammer", "music.note", "cloud", "bolt", "gearshape", "star", "tray.full",
    "message", "chart.bar", "shield",
  ]

  var body: some View {
    let _ = model.imageVersion
    Form {
      TextField("Name", text: $group.name)
      HStack {
        TextField("SF Symbol", text: $group.symbolName)
        Image(systemName: group.symbolName).frame(width: 24)
      }
      HStack(spacing: 6) {
        ForEach(Self.symbols, id: \.self) { symbol in
          Button {
            group.symbolName = symbol
          } label: {
            Image(systemName: symbol).frame(width: 22, height: 22)
          }
          .buttonStyle(.bordered)
        }
      }
      Section("Members") {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.allItems.filter { !ItemMover.isFixed($0) }) { item in
              Toggle(
                isOn: Binding(
                  get: { group.memberKeys.contains(item.key) },
                  set: { model.setMembership(item.key, group: group.id, isMember: $0) })
              ) {
                HStack {
                  ItemImageView(
                    image: model.image(for: item), dark: model.images.prefersDarkBackground(for: [item.key]))
                  Text(item.displayName)
                  if let other = model.settings.group(containing: item.key), other.id != group.id {
                    Text("in \(other.name)").font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
            let missing = group.memberKeys.filter { model.snapshot.item(for: $0) == nil }
            ForEach(missing, id: \.self) { key in
              Text("\(key.rawValue) (not running)").foregroundStyle(.secondary)
            }
          }
        }
        .frame(minHeight: 220)
      }
      HStack {
        Button("Hide Members in Menu Bar") { model.hideMembers(of: group.id) }
        Text("Moves members to Hidden so they only appear through this group.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - General

private struct GeneralTab: View {
  @ObservedObject var model: AppModel
  @State private var launchAtLogin = LaunchAtLogin.isEnabled
  @State private var launchError: String?

  var body: some View {
    Form {
      Section("Menu bar icon") {
        IconPicker(model: model)
      }
      Section("Revealing hidden items") {
        Picker("Show hidden items", selection: $model.settings.revealStyle) {
          ForEach(RevealStyle.allCases) { Text($0.title).tag($0) }
        }
        if model.settings.revealStyle == .menuBar {
          LabeledContent("Hide again after") {
            Slider(value: $model.settings.autoRehideDelay, in: 3...60, step: 1)
            Text("\(Int(model.settings.autoRehideDelay)) s").monospacedDigit().frame(width: 44)
          }
        }
        LabeledContent("Keep an opened item for") {
          Slider(value: $model.settings.activationShowDuration, in: 2...30, step: 1)
          Text("\(Int(model.settings.activationShowDuration)) s").monospacedDigit().frame(width: 44)
        }
        Toggle("⌥-click shows Always Hidden items too", isOn: $model.settings.optionClickShowsAlwaysHidden)
        Toggle("Leave group members out of the MyBar Bar", isOn: $model.settings.hideGroupMembersFromBar)
      }
      Section("Shortcuts and startup") {
        Toggle("Toggle hidden items with \(Hotkey.displayString)", isOn: $model.settings.hotkeyEnabled)
        Toggle("Launch MyBar at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in
            do {
              try LaunchAtLogin.set(enabled)
              launchError = nil
            } catch {
              launchError = error.localizedDescription
              launchAtLogin = LaunchAtLogin.isEnabled
            }
          }
        if let launchError {
          Text(launchError).font(.caption).foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Chooses MyBar's own menu bar icon: a built-in style, any SF Symbol, or
/// a picture.
private struct IconPicker: View {
  @ObservedObject var model: AppModel
  @State private var symbolName = ""
  @State private var message: String?

  private let columns = Array(repeating: GridItem(.fixed(70), spacing: 8), count: 6)

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
        ForEach(ControlIconStyle.all) { style in
          tile(for: .style(style.id), title: style.title)
        }
      }
      HStack {
        TextField("SF Symbol name, e.g. bolt.fill", text: $symbolName)
          .textFieldStyle(.roundedBorder)
          .onSubmit(useSymbol)
        Button("Use Symbol", action: useSymbol)
          .disabled(symbolName.trimmingCharacters(in: .whitespaces).isEmpty)
        if case .symbol = model.settings.controlIcon { tileImage(model.settings.controlIcon) }
      }
      HStack {
        Button("Choose Image…", action: chooseImage)
        if case .image(let template) = model.settings.controlIcon {
          tileImage(model.settings.controlIcon)
          Toggle(
            "Match the menu bar's colour",
            isOn: Binding(get: { template }, set: { model.settings.controlIcon = .image(template: $0) }))
        }
      }
      if let message {
        Text(message).font(.caption).foregroundStyle(.red)
      }
      Text(
        "Symbols come from SF Symbols (Apple's free app lists every name). A filled variant, when there is one, "
          + "shows while hidden items are shown. Pictures are scaled to the menu bar; turn off "
          + "\"Match the menu bar's colour\" to keep a coloured picture's own colours."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private func tile(for icon: ControlIcon, title: String) -> some View {
    let selected = model.settings.controlIcon == icon
    return Button {
      model.settings.controlIcon = icon
      message = nil
    } label: {
      VStack(spacing: 5) {
        tileImage(icon)
        Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
      }
      .frame(width: 70, height: 52)
      .background(
        RoundedRectangle(cornerRadius: 8).fill(
          selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
      )
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
  }

  private func tileImage(_ icon: ControlIcon) -> some View {
    Image(nsImage: ControlIconRenderer.image(for: icon, expanded: false))
      .renderingMode(isTemplate(icon) ? .template : .original)
      .frame(height: 20)
  }

  private func isTemplate(_ icon: ControlIcon) -> Bool {
    if case .image(let template) = icon { return template }
    return true
  }

  private func useSymbol() {
    let name = symbolName.trimmingCharacters(in: .whitespaces)
    guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
      message = "There's no SF Symbol named \"\(name)\"."
      return
    }
    model.settings.controlIcon = .symbol(name)
    message = nil
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = CustomIconStore.allowedTypes
    panel.message = "Choose a picture for MyBar's menu bar icon"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try CustomIconStore.save(from: url)
      if case .image = model.settings.controlIcon {
        model.refreshControlIcon()
      } else {
        model.settings.controlIcon = .image(template: true)
      }
      message = nil
    } catch {
      message = "MyBar couldn't use that picture."
    }
  }
}

// MARK: - Permissions

private struct PermissionsTab: View {
  @ObservedObject var model: AppModel
  @State private var copied = false
  @State private var confirmingReset = false

  var body: some View {
    Form {
      if let problem = Permissions.locationProblem {
        Section {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      Section {
        PermissionRow(
          title: "Accessibility",
          detail: "Required. Identifies which app owns each item and lets MyBar arrange and open items.",
          granted: model.accessibilityGranted,
          request: Permissions.requestAccessibility,
          open: { Permissions.openPrivacyPane("Privacy_Accessibility") })
        PermissionRow(
          title: "Screen & System Audio Recording",
          detail: MenuBarSystem.usesAgent
            ? "Required. Lets MyBar take pictures of menu bar items to show hidden ones in the Bar."
            : "Required. Lets MyBar find its dividers (macOS hides menu bar item names without it), cover the menu bar while it rearranges items, and show real pictures of hidden items in the Bar.",
          granted: model.screenRecordingGranted,
          request: Permissions.requestScreenRecording,
          open: { Permissions.openPrivacyPane("Privacy_ScreenCapture") })
      } footer: {
        Text("After granting a permission you may need to quit and reopen MyBar.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !model.accessibilityGranted || !model.screenRecordingGranted {
        Section {
          HStack {
            Text(
              "Switched on in System Settings but still red here? The switch may belong to an earlier copy of MyBar. Reset clears MyBar's entries and reopens it so you can grant them again."
            )
            .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Permissions…") { confirmingReset = true }
          }
        }
      }
      Section {
        HStack {
          Text("If MyBar doesn't find your menu bar items, copy a report and attach it to an issue on GitHub.")
            .foregroundStyle(.secondary)
          Spacer()
          Button(copied ? "Copied" : "Copy Diagnostics") {
            model.copyDiagnostics()
            copied = true
          }
        }
      }
      Section("How MyBar works") {
        Text(
          MenuBarSystem.usesAgent
            ? """
            Put items in Hidden or Always Hidden on the Layout tab and macOS takes them out of the menu bar. \
            Click MyBar's icon to see them in the Bar below the menu bar; clicking one there opens it in its \
            usual place for a moment. MyBar hides items app by app, and puts everything back when it quits.
            """
            : """
            MyBar adds two thin dividers to your menu bar. Items to the left of the solid divider are Hidden; \
            items to the left of the dashed divider are Always Hidden. When collapsed, the dividers stretch and \
            push those items off screen. Click MyBar's chevron to see them.
            """
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("Reset MyBar's permissions?", isPresented: $confirmingReset) {
      Button("Reset and Reopen MyBar", action: Permissions.resetAndRelaunch)
    } message: {
      Text("MyBar will quit, reopen, and ask for Accessibility and Screen Recording again.")
    }
  }
}

private struct PermissionRow: View {
  let title: String
  let detail: String
  let granted: Bool
  let request: () -> Void
  let open: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(granted ? .green : .red)
        .font(.title2)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      if !granted {
        Button("Grant…", action: request)
        Button("Open Settings", action: open)
      }
    }
    .padding(.vertical, 4)
  }
}

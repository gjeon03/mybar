import AppKit
import MyBarCore

/// One entry shown in MyBar's floating bar.
struct BarEntry {
  let key: ItemKey
  let name: String
  let image: NSImage
}

/// A floating strip below the menu bar that shows pictures of hidden items.
/// Clicking a picture opens the real item.
@MainActor
final class BarPanelController {
  var onSelect: ((ItemKey, NSEvent) -> Void)?
  var onClose: (() -> Void)?

  private let panel: NSPanel
  private let stack = NSStackView()
  private let effect = NSVisualEffectView()
  private var outsideClickMonitor: Any?
  private var keyMonitor: Any?
  private var buttons: [ItemKey: NSButton] = [:]
  private(set) var context: String?

  var isShown: Bool { panel.isVisible && context != nil }

  init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    // MyBar fades the bar itself.
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    effect.material = .menu
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 12
    effect.layer?.masksToBounds = true

    stack.orientation = .horizontal
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      stack.topAnchor.constraint(equalTo: effect.topAnchor),
      stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    panel.contentView = effect
  }

  /// Shows `entries` below `anchor` (a window-server frame of a menu bar item).
  func show(entries: [BarEntry], anchor: CGRect, title: String?, context: String, prefersDark: Bool) {
    self.context = context
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    buttons = [:]

    if let title {
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: 12, weight: .semibold)
      label.textColor = .secondaryLabelColor
      stack.addArrangedSubview(label)
      stack.setCustomSpacing(8, after: label)
    }
    if entries.isEmpty {
      let label = NSTextField(labelWithString: "No hidden items")
      label.textColor = .secondaryLabelColor
      stack.addArrangedSubview(label)
    }
    for entry in entries {
      let button = ItemButton(entry: entry, target: self, action: #selector(entryClicked(_:)))
      buttons[entry.key] = button
      stack.addArrangedSubview(button)
    }

    panel.appearance = NSAppearance(named: prefersDark ? .darkAqua : .aqua)
    stack.layoutSubtreeIfNeeded()
    let size = stack.fittingSize
    let wasShown = panel.isVisible && panel.alphaValue > 0
    panel.setFrame(frame(for: size, anchor: anchor), display: true)
    if !wasShown { panel.alphaValue = 0 }
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { animation in
      animation.duration = 0.1
      panel.animator().alphaValue = 1
    }
    installMonitors()
  }

  func updateImage(_ image: NSImage, for key: ItemKey) {
    (buttons[key] as? ItemButton)?.setItemImage(image)
  }

  func close() {
    guard panel.isVisible, context != nil else { return }
    Log.app.debug("bar closed")
    removeMonitors()
    context = nil
    onClose?()
    NSAnimationContext.runAnimationGroup { animation in
      animation.duration = 0.12
      panel.animator().alphaValue = 0
    } completionHandler: { [panel] in
      MainActor.assumeIsolated {
        // A new bar may have been shown while this one faded out.
        if panel.alphaValue == 0 { panel.orderOut(nil) }
      }
    }
  }

  /// The entry under `point` (window-server coordinates) in the bar as it was
  /// last shown, even if it is fading out.
  func entry(at point: CGPoint) -> ItemKey? {
    let location = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    return buttons.first { _, button in
      guard let window = button.window else { return false }
      let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
      return frame.contains(location)
    }?.key
  }

  /// Marks the entry being opened while MyBar brings its item out, so the
  /// click is acknowledged before the bar goes away.
  func markOpening(_ key: ItemKey) {
    (buttons[key] as? ItemButton)?.isOpening = true
    // MyBar's own synthesized clicks would otherwise count as clicks outside.
    removeMonitors()
  }

  private func frame(for size: NSSize, anchor: CGRect) -> NSRect {
    let anchorFrame = anchor.flippedToAppKit
    let screen =
      MenuBarScanner.displayMapping().display(of: anchor).flatMap(NSScreen.screen(withBounds:))
      ?? NSScreen.main ?? NSScreen.screens[0]
    let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
    let width = min(size.width, screen.frame.width - 16)
    var x = anchorFrame.maxX - width
    x = min(x, screen.frame.maxX - width - 8)
    x = max(x, screen.frame.minX + 8)
    let y = screen.frame.maxY - max(menuBarHeight, 24) - size.height - 4
    return NSRect(x: x, y: y, width: width, height: size.height)
  }

  @objc private func entryClicked(_ sender: ItemButton) {
    guard let event = NSApp.currentEvent else { return }
    onSelect?(sender.entryKey, event)
  }

  private func installMonitors() {
    removeMonitors()
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      MainActor.assumeIsolated {
        Log.app.debug("bar closed by a click outside")
        self?.close()
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {
        self?.close()
        return nil
      }
      return event
    }
  }

  private func removeMonitors() {
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    outsideClickMonitor = nil
    keyMonitor = nil
  }
}

/// A borderless button showing one item's picture, highlighted on hover.
private final class ItemButton: NSButton {
  let entryKey: ItemKey
  private var hovering = false { didSet { needsDisplay = true } }
  var isOpening = false { didSet { needsDisplay = true } }

  init(entry: BarEntry, target: AnyObject, action: Selector) {
    entryKey = entry.key
    super.init(frame: .zero)
    self.target = target
    self.action = action
    isBordered = false
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    toolTip = entry.name
    setAccessibilityLabel(entry.name)
    sendAction(on: [.leftMouseUp, .rightMouseUp])
    wantsLayer = true
    layer?.cornerRadius = 6
    setItemImage(entry.image)
    addTrackingArea(
      NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setItemImage(_ image: NSImage) {
    self.image = image
    let height: CGFloat = 26
    let width = max(26, min(240, image.size.height > 0 ? image.size.width * height / image.size.height : 26))
    removeConstraints(constraints)
    widthAnchor.constraint(equalToConstant: width).isActive = true
    heightAnchor.constraint(equalToConstant: height).isActive = true
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func rightMouseUp(with event: NSEvent) {
    _ = target.map { NSApp.sendAction(action!, to: $0, from: self) }
  }

  override func updateLayer() {
    super.updateLayer()
    let alpha: CGFloat = isOpening ? 0.28 : hovering ? 0.15 : 0
    layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
  }

  override var wantsUpdateLayer: Bool { true }
}

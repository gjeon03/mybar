import AppKit
import MyBarCore
import os

/// Conceals menu bar items on macOS 27+ (see `Concealment`).
///
/// MenuBarAgent's assessment mode shows only the items of an allowed list
/// of apps. It is reached through MenuBarClientCore, a private framework,
/// looked up at run time so that MyBar still launches where it is missing.
/// When MyBar quits, the system lifts the restriction by itself.
@MainActor
final class Concealer {
  /// Apps whose items are concealed, and the section each belongs to.
  private(set) var concealed: [String: MenuBarSection]
  /// Concealed apps shown for the moment (an item being opened).
  private var revealed: Set<String> = []
  /// Every app shown for the moment (pictures being taken, items revealed
  /// in the menu bar), without forgetting what is concealed.
  private var revealAllSources: Set<String> = []

  /// Called with the new list whenever it changes, to save it.
  var onChange: (([String: MenuBarSection]) -> Void)?

  private let assertion = AssessmentAssertion()
  private var lastAllowed: [String]?
  private var isSuspended = false
  private var launchObservers: [NSObjectProtocol] = []

  /// The concealed apps as last applied, for the scanner (which runs off the
  /// main actor) to tell sections by.
  nonisolated static let current = OSAllocatedUnfairLock<[String: MenuBarSection]>(initialState: [:])

  init(concealed: [String: MenuBarSection]) {
    self.concealed = concealed
    Self.current.withLock { $0 = concealed }
    // New apps are only shown if they are on the allowed list.
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      launchObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in await self?.apply() }
        })
    }
  }

  var isAvailable: Bool { assertion.isAvailable }

  func section(of key: ItemKey) -> MenuBarSection {
    Concealment.section(of: key, concealed: concealed)
  }

  /// Puts the app that owns `key` (or, for Control Center's items, the
  /// item itself) in `section` (Visible shows it again).
  func assign(_ key: ItemKey, to section: MenuBarSection) async {
    let concealmentKey = Concealment.concealmentKey(of: key)
    concealed[concealmentKey] = section == .visible ? nil : section
    let value = concealed
    Self.current.withLock { $0 = value }
    onChange?(concealed)
    await apply()
  }

  /// Shows the item with `key` until `conceal(_:)`.
  func reveal(_ key: ItemKey) async {
    revealed.insert(Concealment.concealmentKey(of: key))
    await apply()
  }

  func conceal(_ key: ItemKey) async {
    revealed.remove(Concealment.concealmentKey(of: key))
    await apply()
  }

  func concealAllRevealed() async {
    guard !revealed.isEmpty else { return }
    revealed.removeAll()
    await apply()
  }

  /// Shows every app (for `source`) until `endRevealAll(for:)`.
  func revealAll(for source: String) async {
    revealAllSources.insert(source)
    await apply()
  }

  func endRevealAll(for source: String) async {
    revealAllSources.remove(source)
    await apply()
  }

  var isRevealingAll: Bool { !revealAllSources.isEmpty }

  /// Lifts the restriction altogether until `resume()`. Showing every app
  /// isn't enough for some system features, such as opening Notification
  /// Center, which stay off while any restriction is in force.
  func suspend() {
    isSuspended = true
    assertion.invalidate()
    lastAllowed = nil
  }

  func resume() async {
    isSuspended = false
    await apply()
  }

  /// Tells MenuBarAgent the current allowed list, if it changed.
  func apply() async {
    guard !isSuspended else { return }
    let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    let allowed = Concealment.allowedBundles(
      running: running, concealed: concealed, revealed: revealed, revealAll: !revealAllSources.isEmpty)
    applySystemModules()
    guard allowed != lastAllowed else { return }
    lastAllowed = allowed
    Log.app.info(
      "conceal: allowing \(allowed.count) apps, hiding \(self.concealed.keys.sorted(), privacy: .public)")
    var watch = Stopwatch("conceal")
    let ok = await assertion.activate(allowedBundles: allowed, systemItems: Concealment.allSystemItems)
    watch.lap(ok ? "applied" : "failed")
    if !ok { lastAllowed = nil }
    // Suspended while the list was being applied.
    if isSuspended {
      assertion.invalidate()
      lastAllowed = nil
    }
  }
}

extension Concealer {
  /// Hides or shows Control Center's items (see `SystemModules`): those
  /// concealed and not revealed get the hidden value; the others MyBar hid
  /// get their own value back. Original values are kept until restored, in
  /// case MyBar stops before it can put them back.
  fileprivate func applySystemModules() {
    let showAll = isRevealingAll
    var originals = SystemModulePreferences.originals
    for (identifier, preferenceKey) in SystemModules.allPreferenceKeys {
      let key = ItemKey("\(SystemModules.bundleID)/\(identifier)")
      let hide = concealed[key.rawValue] != nil && !showAll && !revealed.contains(key.rawValue)
      if hide {
        guard let current = SystemModulePreferences.value(for: preferenceKey), SystemModules.isShown(current) else {
          continue
        }
        if originals[preferenceKey] == nil { originals[preferenceKey] = current }
        SystemModulePreferences.set(SystemModules.hiddenValue, for: preferenceKey)
      } else if let original = originals[preferenceKey] {
        SystemModulePreferences.set(original, for: preferenceKey)
        originals[preferenceKey] = nil
      }
    }
    SystemModulePreferences.originals = originals
  }

  /// Puts back every Control Center item MyBar hid (when MyBar quits; the
  /// app restriction lifts by itself, but these preferences stay).
  func restoreSystemModules() {
    for (preferenceKey, original) in SystemModulePreferences.originals {
      SystemModulePreferences.set(original, for: preferenceKey)
    }
    SystemModulePreferences.originals = [:]
  }
}

/// Control Center's per-host preferences for its menu bar modules.
private enum SystemModulePreferences {
  private static let originalsKey = "MyBarSystemModuleOriginals"
  private static let domain = SystemModules.domain as CFString

  /// The values modules had before MyBar hid them.
  static var originals: [String: Int] {
    get { UserDefaults.standard.dictionary(forKey: originalsKey) as? [String: Int] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: originalsKey) }
  }

  static func value(for key: String) -> Int? {
    CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
  }

  static func set(_ value: Int, for key: String) {
    CFPreferencesSetValue(
      key as CFString, value as CFNumber, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
  }
}

/// MenuBarClientCore's `MBAssessmentModeAssertion`, called through the
/// Objective-C runtime.
@MainActor
private final class AssessmentAssertion {
  private typealias InitConfiguration = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
  private typealias Activate =
    @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void

  private let configurationClass: AnyClass?
  private let assertionClass: NSObject.Type?
  private var assertion: NSObject?

  init() {
    dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/Versions/A/MenuBarClientCore", RTLD_NOW)
    configurationClass = NSClassFromString("MBAssessmentModeConfiguration")
    assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type
  }

  var isAvailable: Bool {
    guard let configurationClass, let assertionClass else { return false }
    return (configurationClass as? NSObject.Type)?.instancesRespond(to: Self.initSelector) == true
      && assertionClass.instancesRespond(to: Self.activateSelector)
  }

  private static let initSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
  private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")

  /// Lets the restriction go.
  func invalidate() {
    assertion?.perform(NSSelectorFromString("invalidate"))
    assertion = nil
  }

  /// Applies a new allowed list. Returns whether MenuBarAgent accepted it
  /// within a second.
  func activate(allowedBundles: [String], systemItems: [Int]) async -> Bool {
    guard isAvailable, let configurationClass, let assertionClass,
      let initMethod = class_getInstanceMethod(configurationClass, Self.initSelector),
      let activateMethod = class_getInstanceMethod(assertionClass, Self.activateSelector),
      let raw = (configurationClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    else {
      Log.app.error("assessment mode is not available")
      return false
    }
    let initialize = unsafeBitCast(method_getImplementation(initMethod), to: InitConfiguration.self)
    guard
      let configuration = initialize(
        raw, Self.initSelector, systemItems.map { NSNumber(value: $0) } as NSArray, allowedBundles as NSArray)
    else { return false }
    // An activated assertion only ever lets more through: a stricter list
    // takes a new assertion, and the old one is let go once the new one is
    // in place (until then the two together are as lenient as the old).
    let assertion = assertionClass.init()
    let activate = unsafeBitCast(method_getImplementation(activateMethod), to: Activate.self)
    let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let once = OSAllocatedUnfairLock(initialState: false)
      func finish(_ ok: Bool) {
        guard
          once.withLock({ done in
            defer { done = true }; return !done
          })
        else { return }
        continuation.resume(returning: ok)
      }
      activate(assertion, Self.activateSelector, configuration) { error in
        if let error { Log.app.error("assessment mode activation failed: \(error.localizedDescription)") }
        finish(error == nil)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(false) }
    }
    if accepted {
      self.assertion?.perform(NSSelectorFromString("invalidate"))
      self.assertion = assertion
    } else {
      assertion.perform(NSSelectorFromString("invalidate"))
    }
    return accepted
  }
}

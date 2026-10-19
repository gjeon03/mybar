import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    PreviousIdentity.importSettings()
    let model = AppModel()
    self.model = model
    model.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    model?.prepareToQuit()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    model?.openSettings()
    return true
  }
}

/// MyBar was once identified as `dev.mybar.MyBar`; macOS keeps each identity's
/// settings apart, so bring them over the first time this one runs.
@MainActor
enum PreviousIdentity {
  static let bundleID = "dev.mybar.MyBar"
  private static let importedKey = "MyBarImportedPreviousSettings"

  static func importSettings() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: importedKey) else { return }
    defaults.set(true, forKey: importedKey)
    guard defaults.object(forKey: AppModel.settingsKey) == nil,
      let previous = defaults.persistentDomain(forName: bundleID)
    else { return }
    for (key, value) in previous {
      defaults.set(value, forKey: key)
    }
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  app.run()
}

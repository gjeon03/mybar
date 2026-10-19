import CoreGraphics
import Foundation
import Testing

@testable import MyBarCore

private func window(_ id: CGWindowID, x: CGFloat, width: CGFloat, title: String = "Item-0") -> WindowInfo {
  WindowInfo(
    windowID: id, frame: CGRect(x: x, y: 0, width: width, height: 39), title: title, ownerPID: 685,
    ownerName: "Control Center", isOnScreen: true)
}

private func ax(_ bundle: String, x: CGFloat, width: CGFloat, identifier: String? = nil, label: String? = nil)
  -> AXItemInfo
{
  AXItemInfo(
    bundleID: bundle, pid: 1, appName: bundle.components(separatedBy: ".").last ?? bundle,
    frame: CGRect(x: x, y: 0, width: width, height: 24), identifier: identifier, title: nil, label: label)
}

@Suite struct ItemMatcherTests {
  @Test func matchesByContainedCenter() {
    let windows = [window(1, x: 1321, width: 34), window(2, x: 1353, width: 46)]
    let axItems = [ax("com.kyome.RunCat", x: 1353, width: 46), ax("org.p0deje.Maccy", x: 1321, width: 34)]
    let items = ItemMatcher.match(windows: windows, axItems: axItems)
    #expect(items.map(\.bundleID) == ["org.p0deje.Maccy", "com.kyome.RunCat"])
    #expect(items.map(\.key.rawValue) == ["org.p0deje.Maccy/Item-0", "com.kyome.RunCat/Item-0"])
  }

  @Test func prefersAccessibilityIdentifierForKeys() {
    let windows = [window(5, x: 1398, width: 42, title: "Battery")]
    let axItems = [ax("com.apple.controlcenter", x: 1406, width: 26, identifier: "com.apple.menuextra.battery")]
    let items = ItemMatcher.match(windows: windows, axItems: axItems)
    #expect(items.first?.key.rawValue == "com.apple.controlcenter/com.apple.menuextra.battery")
  }

  @Test func leavesUnmatchedWindowsWithFallbackKey() {
    let items = ItemMatcher.match(windows: [window(9, x: 100, width: 30, title: "statusItem")], axItems: [])
    #expect(items.first?.owner == nil)
    #expect(items.first?.key.rawValue == "Control Center/statusItem")
  }

  @Test func fallsBackToRememberedOwners() {
    // Off screen on some menu bars, Accessibility reports a meaningless position.
    let windows = [window(7, x: -4200, width: 38), window(8, x: -4162, width: 36)]
    let axItems = [ax("com.kakao.KakaoTalkMac", x: 89, width: 24)]
    let remembered = [CGWindowID(7): ax("com.kakao.KakaoTalkMac", x: -4193, width: 24)]
    let items = ItemMatcher.match(windows: windows, axItems: axItems, remembered: remembered)
    #expect(items.map(\.key.rawValue) == ["com.kakao.KakaoTalkMac/Item-0", "Control Center/Item-0"])
  }

  @Test func disambiguatesDuplicateKeys() {
    let windows = [window(1, x: 0, width: 30), window(2, x: 40, width: 30)]
    let axItems = [ax("com.example.app", x: 5, width: 20), ax("com.example.app", x: 45, width: 20)]
    let keys = ItemMatcher.match(windows: windows, axItems: axItems).map(\.key.rawValue)
    #expect(keys == ["com.example.app/Item-0", "com.example.app/Item-0#1"])
  }

  @Test func eachAccessibilityElementIsUsedOnce() {
    let windows = [window(1, x: 0, width: 40), window(2, x: 39, width: 40)]
    let axItems = [ax("com.example.a", x: 30, width: 18)]
    let items = ItemMatcher.match(windows: windows, axItems: axItems)
    #expect(items.compactMap(\.owner).count == 1)
  }
}

@Suite struct MenuBarLayoutTests {
  let dividers = DividerFrames(
    hidden: CGRect(x: 1000, y: 0, width: 20, height: 39),
    alwaysHidden: CGRect(x: 700, y: 0, width: 20, height: 39))

  @Test func classifiesBySidesOfDividers() {
    #expect(MenuBarLayout.section(of: CGRect(x: 1100, y: 0, width: 30, height: 39), dividers: dividers) == .visible)
    #expect(MenuBarLayout.section(of: CGRect(x: 800, y: 0, width: 30, height: 39), dividers: dividers) == .hidden)
    #expect(
      MenuBarLayout.section(of: CGRect(x: 600, y: 0, width: 30, height: 39), dividers: dividers) == .alwaysHidden)
  }

  @Test func collapsedDividersStillClassify() {
    let collapsed = DividerFrames(
      hidden: CGRect(x: -3449, y: 0, width: 5001, height: 39),
      alwaysHidden: CGRect(x: -9327, y: 0, width: 5016, height: 39))
    #expect(MenuBarLayout.section(of: CGRect(x: -4232, y: 0, width: 45, height: 39), dividers: collapsed) == .hidden)
    #expect(
      MenuBarLayout.section(of: CGRect(x: -9373, y: 0, width: 46, height: 39), dividers: collapsed) == .alwaysHidden)
    #expect(MenuBarLayout.section(of: CGRect(x: 1552, y: 0, width: 36, height: 39), dividers: collapsed) == .visible)
  }

  @Test func withoutDividersEverythingIsVisible() {
    let none = DividerFrames(hidden: nil, alwaysHidden: nil)
    #expect(MenuBarLayout.section(of: CGRect(x: 10, y: 0, width: 30, height: 39), dividers: none) == .visible)
  }

  @Test func dropPointsTargetTheCorrectSideOfDividers() {
    let visible = MenuBarLayout.dropPoints(into: .visible, dividers: dividers)
    let hidden = MenuBarLayout.dropPoints(into: .hidden, dividers: dividers)
    let always = MenuBarLayout.dropPoints(into: .alwaysHidden, dividers: dividers)
    #expect(visible.allSatisfy { $0.x > 1010 })
    #expect(hidden.allSatisfy { $0.x < 1010 })
    #expect(always.allSatisfy { $0.x < 710 })
    #expect(!visible.isEmpty && !hidden.isEmpty && !always.isEmpty)
  }

  @Test func sectionsAreOrderedLeftToRight() {
    let items = ItemMatcher.match(
      windows: [window(1, x: 1200, width: 30), window(2, x: 1100, width: 30), window(3, x: 900, width: 30)],
      axItems: [])
    let sections = MenuBarLayout.sections(of: items, dividers: dividers)
    #expect(sections[.visible]?.map(\.id) == [2, 1])
    #expect(sections[.hidden]?.map(\.id) == [3])
    #expect(sections[.alwaysHidden]?.isEmpty == true)
  }
}

@Suite struct SettingsTests {
  @Test func decodesMissingFieldsWithDefaults() throws {
    let settings = try JSONDecoder().decode(MyBarSettings.self, from: Data(#"{"autoRehideDelay": 3}"#.utf8))
    #expect(settings.autoRehideDelay == 3)
    #expect(settings.revealStyle == .bar)
    #expect(settings.groups.isEmpty)
  }

  @Test func roundTripsGroups() throws {
    var settings = MyBarSettings()
    settings.groups = [ItemGroup(name: "Work", memberKeys: [ItemKey("com.example/Item-0")])]
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(MyBarSettings.self, from: data) == settings)
  }

  @Test func assigningMovesItemBetweenGroups() {
    var settings = MyBarSettings()
    let work = ItemGroup(name: "Work")
    let media = ItemGroup(name: "Media")
    settings.groups = [work, media]
    let key = ItemKey("com.example/Item-0")
    settings.assign(key, toGroup: work.id)
    settings.assign(key, toGroup: media.id)
    #expect(settings.group(containing: key)?.id == media.id)
    #expect(settings.groups[0].memberKeys.isEmpty)
    settings.assign(key, toGroup: nil)
    #expect(settings.group(containing: key) == nil)
  }
}

@Suite struct DisplayNameTests {
  @Test func systemItemsUseFirstClauseOfLabel() {
    let item = ItemMatcher.match(
      windows: [window(1, x: 734, width: 38, title: "WiFi")],
      axItems: [ax("com.apple.controlcenter", x: 742, width: 22, label: "Wi‑Fi, connected, 3 bars")]
    ).first
    #expect(item?.displayName == "Wi‑Fi")
  }
}

@Suite struct MenuBarGeometryTests {
  let notched = MenuBarGeometry(screenWidth: 1800, notch: 790...1010)

  @Test func itemsBehindOrLeftOfTheNotchAreUnreachable() {
    #expect(!notched.isReachable(CGRect(x: 851, y: 0, width: 45, height: 39)))
    #expect(!notched.isReachable(CGRect(x: 1000, y: 0, width: 30, height: 39)))
    #expect(notched.isReachable(CGRect(x: 1062, y: 0, width: 34, height: 39)))
    #expect(!notched.isReachable(CGRect(x: 657, y: 0, width: 88, height: 39)))
  }

  @Test func theCursorCanGoBehindTheNotch() {
    #expect(notched.isReachable(CGPoint(x: 900, y: 10)))
    #expect(!notched.isReachable(CGPoint(x: -20, y: 10)))
  }

  @Test func offScreenItemsAreUnreachable() {
    #expect(!notched.isReachable(CGRect(x: -4232, y: 0, width: 45, height: 39)))
    #expect(!notched.isReachable(CGRect(x: 1790, y: 0, width: 30, height: 39)))
  }

  @Test func displaysAwayFromTheOriginUseTheirOwnSpan() {
    let external = MenuBarGeometry(span: -1920...0, notch: nil)
    #expect(external.isReachable(CGRect(x: -500, y: -1080, width: 38, height: 30)))
    #expect(!external.isReachable(CGRect(x: 10, y: -1080, width: 38, height: 30)))
  }

  @Test func displaysWithoutNotchOnlyCheckBounds() {
    let plain = MenuBarGeometry(screenWidth: 2560, notch: nil)
    #expect(plain.isReachable(CGRect(x: 1200, y: 0, width: 30, height: 24)))
    #expect(plain.isReachable(CGPoint(x: 0, y: 10)))
  }
}

@Suite struct DisplayMappingTests {
  // A notched laptop with a 1080p display placed above it, as on the author's desk.
  let mapping = DisplayMapping(
    primary: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    displays: [CGRect(x: 0, y: 0, width: 1800, height: 1169), CGRect(x: 0, y: -1080, width: 1920, height: 1080)])

  @Test func primaryFramesAreUnchanged() {
    let frame = CGRect(x: 1330, y: 0, width: 42, height: 39)
    #expect(mapping.toPrimary(frame, from: mapping.primary) == frame)
  }

  @Test func framesOnOtherDisplaysKeepTheirDistanceFromTheRightEdge() {
    let external = mapping.displays[1]
    #expect(
      mapping.toPrimary(CGRect(x: 1448, y: -1080, width: 42, height: 30), from: external)
        == CGRect(x: 1328, y: 0, width: 42, height: 30))
    // Hidden items are pushed off the left edge; they move by the same offset.
    #expect(mapping.toPrimary(CGRect(x: -4000, y: -1080, width: 40, height: 30), from: external).minX == -4120)
  }

  @Test func activeDisplayIsWhereMostVisibleItemsAre() {
    let onExternal = [
      CGRect(x: -4000, y: -1080, width: 40, height: 30), CGRect(x: 1714, y: -1080, width: 42, height: 30),
      CGRect(x: 1756, y: -1080, width: 164, height: 30),
    ]
    #expect(mapping.activeDisplay(of: onExternal) == mapping.displays[1])
    #expect(mapping.activeDisplay(of: [CGRect(x: 1596, y: 0, width: 42, height: 39)]) == mapping.primary)
    #expect(mapping.activeDisplay(of: []) == mapping.primary)
  }

  @Test func findsTheCopyOnAnotherDisplay() {
    let candidates = [
      CGRect(x: 1404, y: -1080, width: 44, height: 30),
      CGRect(x: 1448, y: -1080, width: 42, height: 30),
      CGRect(x: 1330, y: 0, width: 42, height: 39),
    ]
    let battery = CGRect(x: 1330, y: 0, width: 42, height: 39)
    #expect(mapping.mirror(of: battery, on: mapping.primary, in: candidates) == 1)
    #expect(mapping.mirror(of: CGRect(x: 900, y: 0, width: 42, height: 39), on: mapping.primary, in: candidates) == nil)
    // From the external display back to the laptop.
    let external = CGRect(x: 1448, y: -1080, width: 42, height: 30)
    #expect(mapping.mirror(of: external, on: mapping.displays[1], in: candidates) == 2)
  }

  @Test func placesFramesPushedOffTheSideOfADisplay() {
    #expect(mapping.display(of: CGRect(x: -4000, y: 0, width: 40, height: 39)) == mapping.primary)
    #expect(mapping.display(of: CGRect(x: -4000, y: -1080, width: 40, height: 30)) == mapping.displays[1])
    #expect(mapping.display(of: CGRect(x: 600, y: 400, width: 40, height: 30)) == nil)
  }

  @Test func convertsBetweenAnyTwoDisplays() {
    let external = mapping.displays[1]
    let frame = CGRect(x: 1328, y: 0, width: 42, height: 30)
    #expect(
      mapping.convert(frame, from: mapping.primary, to: external) == CGRect(x: 1448, y: -1080, width: 42, height: 30))
  }
}

@Suite struct ReachPlannerTests {
  let notched = MenuBarGeometry(screenWidth: 1800, notch: 790...1010)

  @Test func shortfallIsTheDistanceToClearTheNotch() {
    #expect(ReachPlanner.shortfall(of: CGRect(x: 657, y: 0, width: 88, height: 39), geometry: notched) == 375)
    #expect(ReachPlanner.shortfall(of: CGRect(x: 1064, y: 0, width: 38, height: 39), geometry: notched) == 0)
    // Just right of the notch, macOS doesn't draw items either.
    #expect(ReachPlanner.shortfall(of: CGRect(x: 1026, y: 0, width: 32, height: 39), geometry: notched) == 6)
    #expect(ReachPlanner.shortfall(of: CGRect(x: 1790, y: 0, width: 38, height: 39), geometry: notched) == nil)
  }

  @Test func prefersTheNarrowestItemThatCoversTheShortfall() {
    let target = CGRect(x: 1000, y: 0, width: 32, height: 39)  // needs 32 to clear the notch and its margin
    let candidates = [
      CGRect(x: 1060, y: 0, width: 38, height: 39),
      CGRect(x: 1098, y: 0, width: 88, height: 39),
      CGRect(x: 1186, y: 0, width: 34, height: 39),
      CGRect(x: 700, y: 0, width: 40, height: 39),  // left of the target
    ]
    #expect(ReachPlanner.itemToShift(leftOf: target, candidates: candidates, geometry: notched) == 2)
  }

  @Test func otherwiseTakesTheWidestReachableItem() {
    let target = CGRect(x: 657, y: 0, width: 88, height: 39)
    let candidates = [
      CGRect(x: 900, y: 0, width: 120, height: 39),  // behind the notch, can't be picked up
      CGRect(x: 1060, y: 0, width: 38, height: 39),
      CGRect(x: 1098, y: 0, width: 44, height: 39),
    ]
    #expect(ReachPlanner.itemToShift(leftOf: target, candidates: candidates, geometry: notched) == 2)
  }

  @Test func avoidsWideItemsWhileIconsAreLeft() {
    let target = CGRect(x: 884, y: 0, width: 32, height: 39)
    let candidates = [
      CGRect(x: 1054, y: 0, width: 88, height: 39),  // a text readout
      CGRect(x: 1142, y: 0, width: 36, height: 39),
    ]
    #expect(ReachPlanner.itemToShift(leftOf: target, candidates: candidates, geometry: notched) == 1)
    #expect(ReachPlanner.itemToShift(leftOf: target, candidates: [candidates[0]], geometry: notched) == 0)
  }

  @Test func dropsInsideTheTargetsLeftHalfAfterItShifts() {
    let target = CGRect(x: 657, y: 0, width: 88, height: 39)
    // A 38-point item is lifted from the right; the target moves to 695.
    let point = ReachPlanner.dropPoint(leftOf: target, carrying: 38, geometry: notched)
    #expect(point == CGPoint(x: 698, y: 19.5))
    // Never left of the target, whatever is carried.
    #expect(point.map { $0.x > target.minX } == true)
    let offScreen = CGRect(x: -400, y: 0, width: 38, height: 39)
    #expect(ReachPlanner.dropPoint(leftOf: offScreen, carrying: 38, geometry: notched) == nil)
  }
}

@Suite struct GlyphPixelsTests {
  /// A premultiplied RGBA buffer of `count` pixels of one colour.
  func pixels(_ count: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> [UInt8] {
    Array([[r, g, b, a]].joined()).repeated(count)
  }

  @Test func blankCapturesAreRejected() {
    #expect(GlyphPixels.analyze([UInt8](repeating: 0, count: 64)) == nil)
  }

  @Test func detectsMonochromeGlyphs() {
    let white = pixels(10, r: 255, g: 255, b: 255, a: 255)
    let analysis = GlyphPixels.analyze(white)
    #expect(analysis?.isMonochrome == true)
    #expect(analysis?.luminance ?? 0 > 0.99)
  }

  @Test func detectsColouredIcons() {
    let blue = pixels(10, r: 20, g: 120, b: 230, a: 255)
    #expect(GlyphPixels.analyze(blue)?.isMonochrome == false)
  }

  @Test func boostsTranslucentGlyphsToFullOpacity() {
    var faint = pixels(4, r: 153, g: 153, b: 153, a: 153)
    #expect(GlyphPixels.analyze(faint)?.maxAlpha ?? 0 < 0.61)
    GlyphPixels.boostAlpha(&faint)
    #expect(faint == pixels(4, r: 255, g: 255, b: 255, a: 255))
  }
}

extension Array {
  fileprivate func repeated(_ times: Int) -> [Element] {
    (0..<times).flatMap { _ in self }
  }
}

@Suite struct AgentLayoutTests {
  // Measured on macOS 27.0 (1800 pt display, notch 790–1010).
  let chevron = CGRect(x: 1130, y: 0, width: 17, height: 39)

  @Test func itemsOverOrLeftOfTheChevronAreFolded() {
    #expect(AgentLayout.isFolded(CGRect(x: 1102, y: 7, width: 46, height: 24), chevron: chevron))
    #expect(AgentLayout.isFolded(CGRect(x: 1114, y: 7, width: 34, height: 24), chevron: chevron))
    #expect(AgentLayout.isFolded(CGRect(x: 1162, y: 7, width: 24, height: 24), chevron: chevron) == false)
    #expect(AgentLayout.isFolded(CGRect(x: 10, y: 7, width: 36, height: 24), chevron: nil) == false)
  }
}

@Suite struct ConcealmentTests {
  let running = ["com.kyome.RunCat", "com.cmuxterm.app", "dev.gimbap.mybar", "com.kyome.RunCat"]

  @Test func allowsEveryRunningAppButTheConcealedOnes() {
    let allowed = Concealment.allowedBundles(
      running: running, concealed: ["com.kyome.RunCat": .hidden], revealed: [], revealAll: false)
    #expect(allowed == ["com.cmuxterm.app", "dev.gimbap.mybar"])
  }

  @Test func revealingAllowsAConcealedAppAgain() {
    let concealed: [String: MenuBarSection] = ["com.kyome.RunCat": .hidden, "com.cmuxterm.app": .alwaysHidden]
    #expect(
      Concealment.allowedBundles(
        running: running, concealed: concealed, revealed: ["com.kyome.RunCat"], revealAll: false)
        == ["com.kyome.RunCat", "dev.gimbap.mybar"])
    #expect(
      Concealment.allowedBundles(running: running, concealed: concealed, revealed: [], revealAll: true)
        == ["com.kyome.RunCat", "com.cmuxterm.app", "dev.gimbap.mybar"])
  }

  @Test func sectionsComeFromTheConcealedApps() {
    let concealed: [String: MenuBarSection] = ["com.cmuxterm.app": .alwaysHidden]
    #expect(Concealment.section(of: ItemKey("com.cmuxterm.app/Item-0"), concealed: concealed) == .alwaysHidden)
    #expect(Concealment.section(of: ItemKey("com.kyome.RunCat/Item-0"), concealed: concealed) == .visible)
    #expect(
      Concealment.bundleID(of: ItemKey("com.apple.controlcenter/com.apple.menuextra.wifi")) == "com.apple.controlcenter"
    )
  }
}

@Suite struct GlyphLiftingTests {
  let bar: [UInt8] = [90, 110, 150, 255]
  let white: [UInt8] = [250, 250, 250, 255]
  let faint: [UInt8] = [95, 112, 152, 255]

  @Test func liftsWhatStandsOutFromTheBar() throws {
    // bar | bar glyph faint bar | bar
    let row = bar + bar + white + faint + bar + bar
    let glyph = try #require(
      GlyphPixels.lift(from: row, width: 6, height: 1, rect: CGRect(x: 1, y: 0, width: 4, height: 1), margin: 1))
    #expect(glyph.width == 4)
    #expect(glyph.pixels[1 * 4 + 3] == 255)  // the white pixel is opaque
    #expect(glyph.pixels[2 * 4 + 3] == 0)  // the near-bar pixel is transparent
  }

  @Test func plainBarHasNoGlyph() {
    let row = bar + bar + bar + bar
    #expect(
      GlyphPixels.lift(from: row, width: 4, height: 1, rect: CGRect(x: 1, y: 0, width: 2, height: 1), margin: 1)
        == nil)
  }

  @Test func aGlyphRunningAcrossTheWholeItemIsRejected() {
    // A neighbour's glyph at both edges: the frame was off.
    let row = bar + white + bar + white + bar
    #expect(
      GlyphPixels.lift(from: row, width: 5, height: 1, rect: CGRect(x: 1, y: 0, width: 3, height: 1), margin: 1)
        == nil)
  }
}

@Suite struct SystemModuleTests {
  @Test func mapsControlCenterItemsToTheirModules() {
    #expect(SystemModules.preferenceKey(for: ItemKey("com.apple.controlcenter/com.apple.menuextra.wifi")) == "WiFi")
    #expect(
      SystemModules.preferenceKey(for: ItemKey("com.apple.controlcenter/com.apple.menuextra.display")) == "Display")
    #expect(SystemModules.preferenceKey(for: ItemKey("com.apple.controlcenter/com.apple.menuextra.clock")) == nil)
    #expect(SystemModules.preferenceKey(for: ItemKey("com.kyome.RunCat/Item-0")) == nil)
  }

  @Test func modulesAreConcealedOneByOne() {
    let wifi = ItemKey("com.apple.controlcenter/com.apple.menuextra.wifi")
    let sound = ItemKey("com.apple.controlcenter/com.apple.menuextra.sound")
    let concealed: [String: MenuBarSection] = [wifi.rawValue: .hidden]
    #expect(Concealment.section(of: wifi, concealed: concealed) == .hidden)
    #expect(Concealment.section(of: sound, concealed: concealed) == .visible)
    #expect(Concealment.concealmentKey(of: wifi) == wifi.rawValue)
    #expect(Concealment.concealmentKey(of: ItemKey("com.kyome.RunCat/Item-0")) == "com.kyome.RunCat")
  }

  @Test func readsWhetherAModuleIsShown() {
    #expect(SystemModules.isShown(2))
    #expect(SystemModules.isShown(18))
    #expect(!SystemModules.isShown(8))
    #expect(!SystemModules.isShown(24))
  }
}

@Suite struct ControlIconTests {
  @Test func stylesHaveUniqueIdentifiers() {
    #expect(Set(ControlIconStyle.all.map(\.id)).count == ControlIconStyle.all.count)
    #expect(ControlIconStyle.style(withID: "nope").id == "chevron")
  }

  @Test func iconChoiceSurvivesSaving() throws {
    var settings = MyBarSettings()
    settings.controlIcon = .symbol("bolt.fill")
    let decoded = try JSONDecoder().decode(MyBarSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.controlIcon == .symbol("bolt.fill"))
    // Settings saved before icons could be chosen get the default.
    let old = try JSONDecoder().decode(MyBarSettings.self, from: Data("{}".utf8))
    #expect(old.controlIcon == .default)
  }
}

@Suite struct GlyphSliverTests {
  @Test func aSliverAtTheEdgeIsRejected() {
    // A 10×10 item with one bright pixel near its right edge, on bar blue.
    let bar: [UInt8] = [90, 110, 150, 255]
    var pixels: [UInt8] = []
    for y in 0..<10 {
      for x in 0..<12 {
        pixels += (x == 9 && y == 5) ? [250, 250, 250, 255] : bar
      }
    }
    #expect(
      GlyphPixels.lift(from: pixels, width: 12, height: 10, rect: CGRect(x: 1, y: 0, width: 10, height: 10), margin: 1)
        == nil)
  }
}

/// What MyBar's own menu bar icon looks like.
public enum ControlIcon: Codable, Equatable, Sendable {
  /// One of the built-in styles (`ControlIconStyle.all`), by identifier.
  case style(String)
  /// Any SF Symbol, by name.
  case symbol(String)
  /// A picture the person chose; MyBar keeps a copy of it.
  case image(template: Bool)

  public static let `default` = ControlIcon.style(ControlIconStyle.all[0].id)
}

/// A built-in look for MyBar's icon: one symbol while items are hidden,
/// another while they are shown.
public struct ControlIconStyle: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  /// SF Symbol shown while hidden items are hidden.
  public let collapsed: String
  /// SF Symbol shown while they are shown.
  public let expanded: String

  /// The built-in styles. `mybar` is drawn by MyBar rather than a symbol.
  public static let all: [ControlIconStyle] = [
    ControlIconStyle(
      id: "chevron", title: "Chevron", collapsed: "chevron.compact.left", expanded: "chevron.compact.right"),
    ControlIconStyle(
      id: "doubleChevron", title: "Double Chevron", collapsed: "chevron.left.2", expanded: "chevron.right.2"),
    ControlIconStyle(id: "dots", title: "Dots", collapsed: "ellipsis", expanded: "ellipsis"),
    ControlIconStyle(
      id: "circleDots", title: "Dots in a Circle", collapsed: "ellipsis.circle", expanded: "ellipsis.circle.fill"),
    ControlIconStyle(
      id: "lines", title: "Lines", collapsed: "line.3.horizontal", expanded: "line.3.horizontal.decrease"),
    ControlIconStyle(id: "grid", title: "Grid", collapsed: "square.grid.2x2", expanded: "square.grid.2x2.fill"),
    ControlIconStyle(id: "eye", title: "Eye", collapsed: "eye.slash", expanded: "eye"),
    ControlIconStyle(id: "star", title: "Star", collapsed: "star", expanded: "star.fill"),
    ControlIconStyle(id: "cocktail", title: "Cocktail", collapsed: "wineglass", expanded: "wineglass.fill"),
    ControlIconStyle(id: "coffee", title: "Coffee", collapsed: "cup.and.saucer", expanded: "cup.and.saucer.fill"),
    ControlIconStyle(id: "mustache", title: "Mustache", collapsed: "mustache", expanded: "mustache.fill"),
    ControlIconStyle(id: "mybar", title: "MyBar", collapsed: "", expanded: ""),
  ]

  public static func style(withID id: String) -> ControlIconStyle {
    all.first { $0.id == id } ?? all[0]
  }
}

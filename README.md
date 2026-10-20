# MyBar

A small, free menu bar organizer for macOS. MyBar hides the menu bar items you don't need all
the time, shows them on demand in a bar below the menu bar, and collects related items into
groups behind a single icon.

**[mybar.gimbap.dev](https://mybar.gimbap.dev)** · [Download](https://github.com/gjeon03/mybar/releases/latest) · MIT licensed

## Features

- **Hidden and Always Hidden** — keep items out of the menu bar; Always Hidden ones only show
  when you ask for everything.
- **The Bar** — click MyBar's icon to see hidden items in a strip below the menu bar. Click one
  and it opens right where it belongs, then goes back into hiding once you're done.
- **Groups** — give a set of items its own menu bar icon that shows just those items.
- **System items too** — on macOS 27, Wi‑Fi, Sound, Battery and other Control Center items can be
  hidden like any app's. Items macOS doesn't let anyone hide (the clock, Control Center) are
  marked as fixed.
- **Layout editor** — drag items between sections in Settings.
- **Your own icon** — 12 built-in looks for MyBar's icon, any SF Symbol, or a picture of your own.
- **Global shortcut** — ⌥⌘B toggles hidden items. Launch at login is supported.

## Requirements

- **macOS 27 (Golden Gate)** — tested on 27.0.1.
- **macOS 26 (Tahoe)** — uses the earlier divider-based engine (see below), tested on 26.6.2.
- Apple silicon or Intel.

## Install

1. Download `MyBar-<version>.dmg` from [Releases](https://github.com/gjeon03/mybar/releases/latest)
   and drag MyBar into Applications.
2. Open MyBar from Applications and allow **Accessibility** and **Screen & System Audio Recording**
   in System Settings › Privacy & Security.
3. Drag the items you want to hide into Hidden on the Layout tab.

If a permission is switched on but MyBar still shows it in red, click **Reset Permissions…** on the
Permissions tab and allow it again (see [docs/releasing.md](docs/releasing.md) for why).

| Permission | Needed for |
| --- | --- |
| Accessibility | Finding menu bar items and their apps, opening items |
| Screen & System Audio Recording | Pictures of hidden items in the Bar; on macOS 26 also reading item names and covering the menu bar while rearranging |

MyBar doesn't collect or send anything; the code is all here.

## How it works

### macOS 27

macOS 27 draws the whole menu bar in a new system process (MenuBarAgent) and no longer gives each
item its own window. MyBar hides apps through the menu bar's allow list (an assessment-mode
assertion in the private MenuBarClientCore framework): every running app except the hidden ones is
allowed. To open a hidden item, MyBar allows its app for a moment, waits for the item to appear in
place and presses it through Accessibility. Apple's own items are Control Center modules, hidden
through Control Center's per-host preferences and restored when MyBar quits. When MyBar quits, the
system lifts the allow list and every item returns. Details: [docs/macos27.md](docs/macos27.md).

### macOS 26

MyBar adds two status items that act as dividers. When collapsed, a divider is stretched
far wider than the screen, which pushes every item to its left off the edge of the display.
Expanding the divider shrinks it back to a thin line so those items return.

Rearranging items uses the same command-drag that macOS supports for people, synthesized
with `CGEvent`. Each move is verified with a fresh scan and retried if needed.

Clicking an item in the MyBar Bar shows that item alone: MyBar moves it next to its icon,
clicks it, and moves it back to its section once the menu has been closed for a few seconds
(items waiting to go back are remembered across relaunches).

On macOS 26 all status-item windows are owned by Control Center, so MyBar identifies each
item by matching the window's frame against the `AXExtrasMenuBar` elements that each
application exposes through Accessibility. With several displays, the real status-item
windows live in the menu bar the user is working in and the other displays show copies;
MyBar follows the real ones (its own icon keeps its autosave name only there) and relates
displays by each item's distance from the right edge, which every copy shares.

Pictures for the MyBar Bar are captured with ScreenCaptureKit. macOS only draws items that
are on screen, so when pictures are missing or older than ten minutes MyBar briefly expands
the menu bar, captures what became visible (also from other displays' menu bars, which have
no notch) and caches the pictures on disk. Monochrome pictures are shown as template images
so they match the bar's appearance. Items macOS never draws, such as ones under the notch,
fall back to their app's icon. Without Screen Recording permission, app icons are used.

## Building

Requires Xcode 16 or later (Swift 6 toolchain).

```bash
swift test                     # unit tests for MyBarCore
scripts/build-app.sh           # builds build/MyBar.app (release)
scripts/install.sh             # builds, installs to /Applications and launches
scripts/package.sh build       # universal app in a disk image
```

Builds are signed with `MYBAR_SIGN_IDENTITY` if set, else a Developer ID Application certificate
from the keychain, else ad hoc. Ad-hoc signatures change with every build, so macOS asks for
permissions again after each update. Releasing and notarizing: [docs/releasing.md](docs/releasing.md).
`swift scripts/make-icon.swift` regenerates the app icon.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/MyBarCore` | Pure logic: item identity and matching, section layout, drop planning, settings and groups |
| `Sources/MyBar` | The app: status items, scanner, mover, activator, floating bar, settings window |
| `Tests/MyBarCoreTests` | Unit tests for `MyBarCore` |
| `docs/` | Architecture, measured macOS behavior, development and testing guide, releasing (Korean) — start at [docs/README.md](docs/README.md) |
| `site/` | The website, published with GitHub Pages |
| `tools/` | Development tools for real-world testing (`tools/build.sh`) |
| `scripts/` | Build, install, package (`scripts/package.sh` makes a shareable DMG), icon |

## Limitations

- macOS 27: items are hidden app by app; an app with several items can't split them. When the
  menu bar is full, macOS may still fold items behind its own `«`. MyBar relies on private
  interfaces that a macOS update can change.
- macOS 27: if MyBar is force-quit, hidden Apple items (Wi‑Fi etc.) stay hidden until MyBar runs
  again or you turn them back on in System Settings › Menu Bar.
- macOS 27: while items are hidden, macOS ignores the clock, so MyBar opens Notification Center
  for you when you click it. It briefly lets hidden items back under a picture of the menu bar,
  so the screen recording indicator shows for a moment and the menu bar shifts slightly.
  Swiping in from the right edge of the trackpad doesn't open Notification Center.
- macOS 27: the input source and VPN items appear only on the active display's menu bar; this is
  how macOS draws them, with or without MyBar.
- macOS 26: on a display with a notch, macOS only draws (and lets anyone drag) items to the right of
  the notch. To reach an item behind or left of it, MyBar drops drawn items of the same
  section just left of it until it slides into reach, which takes about 0.2 s per
  item; the order within the section changes as a result. When rearranging from Settings and
  another display without a notch is connected, MyBar may activate that menu bar and move it there.
- The clock and Control Center icons are fixed by macOS and can't be moved.
- All displays share one layout, as in macOS itself.

## Debug builds

Debug builds (`scripts/build-app.sh debug`) accept commands as distributed notifications
named `dev.gimbap.mybar.debug` and write the resulting state to `/tmp/mybar-debug.json` (or
`MYBAR_DEBUG_OUT`). See `Sources/MyBar/DebugControl.swift` for the commands.

## License

[MIT](LICENSE)

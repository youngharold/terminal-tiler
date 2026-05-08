# Terminal Tiler

Menu-bar app for macOS that tiles every open Terminal.app window into a grid covering the screen. Click a tile to zoom it for typing — others tuck into a sidebar strip. Esc returns to the even grid. Stop tiling to restore each window's original frame.

## Build

```sh
./build-app.sh
```

Produces `TerminalTiler.app` in the project root.

## Install

```sh
cp -R TerminalTiler.app /Applications/
open /Applications/TerminalTiler.app
```

On first launch macOS will prompt for **Accessibility permission**. Grant it in System Settings → Privacy & Security → Accessibility, then re-launch.

## Auto-launch on login

```sh
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/TerminalTiler.app", hidden:true}'
```

## Use

Click the grid icon in the menu bar:

- **Tile Terminal Windows** — lay out every standard Terminal window in an even grid (one grid per display).
- Click any tile → it zooms. Two zoom styles: **Side Strip** (focused fills 78% on the left, others stack on the right) or **Full Screen** (focused fills the screen).
- **⌘⌥T** — toggle tiling from anywhere.
- **⌘⌥G** — return to the even grid (works from any app; doesn't conflict with vim/REPL Esc behavior in Terminal).
- **⌘⌥⇧T** — Stop tiling and leave windows where they are (no restore).
- **Re-tile Now** / **Refresh Window List** — refresh the layout after opening or closing windows (auto-detects most cases).
- **Stop Tiling** — submenu with two choices: *Restore Originals* (snap each window back to where it was before tiling started) or *Leave Where They Are* (just stop managing the windows in place).

## Notes

- New Terminal windows are auto-detected and added to the grid.
- Windows on multiple displays each tile within their own display.
- After granting Accessibility permission, you may need to relaunch the app for observers to attach (the app will prompt with a System Settings deep-link if permission is missing).

## Requirements

- macOS 13+
- Swift 5.9+
- Apple Silicon or Intel (the build script produces a native binary)

## License

MIT

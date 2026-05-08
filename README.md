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

- **Tile Terminal Windows** — lay out every standard Terminal window in an even grid.
- Click any tile → it zooms to ~78% width on the left; the rest stack on the right strip.
- **Esc** — re-tile back to the even grid.
- **Re-tile Now** — re-detect windows and re-grid (use after opening or closing windows).
- **Stop Tiling** — restore every window to where it was before.

## Requirements

- macOS 13+
- Swift 5.9+
- Apple Silicon or Intel (the build script produces a native binary)

## License

MIT

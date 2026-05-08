# Terminal Tiler

[![Test](https://github.com/youngharold/terminal-tiler/actions/workflows/test.yml/badge.svg)](https://github.com/youngharold/terminal-tiler/actions/workflows/test.yml)

Menu-bar app for macOS that tiles every open Terminal.app window into a grid covering the screen. Click a tile to zoom it for typing — others tuck into a sidebar strip. ⌘⌥G returns to the even grid. Stop tiling to restore each window's original frame.

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

Click the menu bar icon → **Launch at Login**. (Uses `SMAppService` — requires the app to be installed in `/Applications`.)

## Use

Click the grid icon in the menu bar:

- **Tile Terminal Windows** — lay out every standard Terminal window in an even grid (one grid per display).
- Click any tile → it zooms. Two zoom styles: **Side Strip** (focused fills 78% on the left, others stack on the right) or **Full Screen** (focused fills the screen).
- **⌘⌥T** — toggle tiling from anywhere.
- **⌘⌥G** — return to the even grid (works from any app; doesn't conflict with vim/REPL Esc behavior in Terminal).
- **⌘⌥⇧T** — Stop tiling and leave windows where they are (no restore).
- **Return to Grid** / **Refresh Window List** — re-tile or re-detect windows (auto-detects most cases).
- **Exclude Focused Window** — drop the currently-focused tile from tiling and restore its original position. Useful for log tails or monitoring panes that shouldn't move. Re-tile to bring it back.
- **Stop Tiling** — submenu with two choices: *Restore Originals* (snap each window back to its position at the moment tiling started) or *Leave Where They Are* (just stop managing in place).

## Keybindings

| Shortcut    | Action                                        |
|-------------|-----------------------------------------------|
| `⌘⌥T`       | Toggle tiling (start, or *Stop & Restore*)    |
| `⌘⌥G`       | Return to the even grid (cancels a zoom)      |
| `⌘⌥⇧T`      | *Stop & Leave* (windows stay where they are)  |

Hotkeys are global — they fire from any app. They use `charactersIgnoringModifiers` so they map to the physical keys on Dvorak / AZERTY / QWERTZ as well as US-QWERTY.

## Notes

- New Terminal windows are auto-detected and added to the grid (~150ms after they appear).
- Closed windows are dropped automatically; if only one Terminal window remains, tiling stops and that window is restored.
- Windows on multiple displays tile within their own display (no cross-display merging).
- "Restore Originals" snaps each window back to the position it had **at the moment tiling started** — not to a pre-Terminal-Tiler factory default.

## Troubleshooting

- **Menu bar icon is there but tiling does nothing.** Accessibility permission isn't granted to *this exact build*. Open System Settings → Privacy & Security → Accessibility — if Terminal Tiler isn't listed, drag the app in; if it's listed but off, toggle it on. The hotkey monitor retries every ~1.5s, so you don't need to relaunch the app afterwards.
- **`⌘⌥T` does nothing.** Same as above — global key monitoring is gated by Accessibility.
- **Tile button shows "Too many Terminal windows".** With more than ~16 windows on a single display the grid cells become unreadable. Move some windows to another display, or close a few.
- **One Terminal window stays tiled fullscreen after closing siblings.** This shouldn't happen — the app stops and restores when the count drops below 2. If it does, click *Stop & Restore Originals* in the menu.

## Known limitations

- **Terminal.app only.** iTerm2, Ghostty, Alacritty, and Warp use different AX subroles or aren't standard windows; they aren't detected.
- **Single-instance.** Launching a second copy will alert and quit.
- **Ad-hoc signed.** Distributing the prebuilt `.app` outside this Mac will trip Gatekeeper. Build from source with `./build-app.sh` instead.

## Requirements

- macOS 13+
- Swift 5.9+
- Apple Silicon or Intel (the build script produces a native binary)

## License

MIT

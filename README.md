# TermUsher

![TermUsher — macOS terminal window manager](og-image.png)

[![Test](https://github.com/youngharold/termusher/actions/workflows/test.yml/badge.svg)](https://github.com/youngharold/termusher/actions/workflows/test.yml)

> **A macOS menu bar app that seats your terminal windows in a tidy grid.** Built for developers who keep many AI-CLI sessions open at once — Claude Code, Codex, Cursor, Aider, plain shells, you name it. When you're juggling a dozen terminals chasing different agents and tasks, TermUsher tiles them so you can see them all, then quietly steps aside.

Click a tile to zoom it for typing — others tuck into a sidebar strip. Drag a terminal's title bar to reorder. ⌘⌥G or hover the top edge of the screen returns to the even grid. The app can also auto-return after you press Enter and go idle (perfect for chat-style LLM workflows). Stop tiling and TermUsher restores each window to where it was before.

**Built for the AI-CLI workflow.** If your day involves ten Claude Code sessions, three Codex tabs, and a Cursor in the corner, this is for you.

**Tech stack:** Swift Package Manager · AppKit · `ApplicationServices` (Accessibility API) · `ServiceManagement` (Launch at Login) · 24 XCTest cases · GitHub Actions CI on macos-14 · `swift build --arch arm64 --arch x86_64` (universal binary).

## Build

```sh
./build-app.sh
```

Produces `TermUsher.app` in the project root.

## Install

```sh
cp -R TermUsher.app /Applications/
open /Applications/TermUsher.app
```

On first launch macOS will prompt for **Accessibility permission**. Grant it in System Settings → Privacy & Security → Accessibility, then re-launch.

## Auto-launch on login

Click the menu bar icon → **Launch at Login**. (Uses `SMAppService` — requires the app to be installed in `/Applications`.)

## Use

Click the grid icon in the menu bar:

- **Tile Terminal Windows** — lay out every standard Terminal window in an even grid (one grid per display).
- Click any tile → it zooms. Four zoom styles in the **Zoom Style** submenu:
  - **Side Strip** — focused fills 78% on the left, others stack on the right.
  - **Full Screen** — focused fills the screen entirely.
  - **Full Column** — focused expands vertically only (1/N width × full screen height).
  - **Disabled** — clicking does nothing; the static grid stays put.
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

## Auto Return to Grid

Three triggers can return a zoomed window to the grid without you reaching for a hotkey, all toggleable in the **Auto Return to Grid** submenu:

- **After 5 min idle** — no input on screen for 5 minutes → grid.
- **On hover at top edge** — move mouse to the very top of the screen for 0.3s → grid.
- **After ⏎ + 3s idle** — press Return inside the zoomed window, then no further keystrokes for 3 seconds → grid. Best for Claude-CLI / chat-style usage where you send a message and wait for output.

All three are off by default. Enable any combination.

## Drag to reorder

While tiled, drag a Terminal window's title bar to move it. On release, TermUsher snaps it into the closest grid slot and swaps with whatever was there. Order persists for the session — restarting tiling resets to the original order.

## Notes

- New Terminal windows are auto-detected and added to the grid (~150ms after they appear).
- Closed windows are dropped automatically; if only one Terminal window remains, tiling stops and that window is restored.
- Windows on multiple displays tile within their own display (no cross-display merging).
- "Restore Originals" snaps each window back to the position it had **at the moment tiling started** — not to a pre-Terminal-Tiler factory default.

## Troubleshooting

- **Menu bar icon is there but tiling does nothing.** Accessibility permission isn't granted to *this exact build*. Open System Settings → Privacy & Security → Accessibility — if TermUsher isn't listed, drag the app in; if it's listed but off, toggle it on. The hotkey monitor retries every ~1.5s, so you don't need to relaunch the app afterwards.
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

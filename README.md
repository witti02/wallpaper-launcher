# WallpaperLauncher

A keyboard-driven wallpaper picker for macOS, inspired by the rofi / waypaper style launchers common on Arch and other Linux setups.

Press a global hotkey, a floating panel appears with your wallpapers arranged on a rotating 3D ring, pick one, hit Enter — done.

## Features

- **Global hotkey** `⌃⌥W` toggles the launcher from anywhere
- **Rotating ring** — wallpapers sit on a circle that spins smoothly to the selected image; cards in the back shrink, darken and fade
- **Type to search** by file or folder name
- **Keyboard, trackpad and scroll wheel** navigation
- Applies the wallpaper to **all connected displays**
- Marks the currently active wallpaper
- **Random wallpaper** from the menu, with `⌘R`, or via the command line
- **Menu bar app** (no Dock icon): manage folders, rescan, launch at login
- Recursively scans folders; supports JPG, PNG, HEIC, WebP, TIFF, GIF and BMP

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`)

## Build & install

```bash
./build.sh            # builds build/WallpaperLauncher.app
./build.sh --install  # builds and copies it to ~/Applications
open ~/Applications/WallpaperLauncher.app
```

The app is ad-hoc signed, so no developer account is needed.

## Usage

| Key | Action |
|---|---|
| `⌃⌥W` (global) | Open / close the launcher |
| type | Filter wallpapers |
| `←` `→` / `Tab` / scroll | Rotate the ring |
| `Home` / `End` | Jump to first / last |
| `↩` or double-click | Apply wallpaper |
| `⇧↩` | Apply and keep the launcher open |
| `⌘R` | Apply a random wallpaper |
| `esc` | Clear search, then close |

### Folders

By default the launcher reads `~/Pictures/Wallpaper`. Add more folders from the menu bar icon → **Folders → Add Folder…**. Clicking a folder reveals it in Finder; `⌥`-clicking removes it.

### Scripting

```bash
open -a WallpaperLauncher                                               # toggle the launcher (e.g. from skhd or Hammerspoon)
~/Applications/WallpaperLauncher.app/Contents/MacOS/WallpaperLauncher --random      # set a random wallpaper and exit
~/Applications/WallpaperLauncher.app/Contents/MacOS/WallpaperLauncher --background  # start without showing the panel
```

## Notes

- macOS only changes the wallpaper of the **current Space**; this is a limitation of the system API.
- To change the hotkey, edit `registerHotKey()` in `Sources/main.swift` and rebuild.
- "Launch at Login" requires the app to live in `/Applications` or `~/Applications`.

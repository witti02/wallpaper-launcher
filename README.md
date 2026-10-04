# WallpaperLauncher

A keyboard-driven wallpaper picker for macOS, inspired by the rofi / waypaper style launchers common on Arch and other Linux setups.

Press a global hotkey, a floating panel appears with your wallpapers arranged on a rotating 3D ring, pick one, hit Enter — done.

## Features

- **Global hotkey** (default `⌃⌥W`, configurable) toggles the launcher from anywhere
- **Rotating ring** — wallpapers sit on a circle that spins smoothly to the selected image; cards in the back shrink, darken and fade
- **Type to search** by file or folder name
- **Keyboard, trackpad and scroll wheel** navigation
- Applies the wallpaper to **all connected displays**
- Marks the currently active wallpaper
- **Random wallpaper** from the menu, with `⌘R`, or via the command line
- **Light background blur** while the launcher is open
- **Settings window** for folders, file types, sort order, shortcut, scaling, displays and the whole look of the ring
- **Menu bar app** (no Dock icon)
- Supports JPG, PNG, HEIC, WebP, TIFF, GIF and BMP

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
| `⌘,` | Open settings |
| `esc` | Clear search, then close |

### Settings

Open them from the menu bar icon → **Settings…** or with `⌘,` while the launcher is open. Changes apply immediately.

| Tab | Options |
|---|---|
| **General** | global shortcut (click and press a new combination), apply to all / main / display under the mouse, scaling (fill, fit, stretch, center), close after applying, start at the current wallpaper, launch at login |
| **Folders** | add, remove and temporarily disable folders, include subfolders per folder, file types, sort order (name, newest, oldest, shuffle) |
| **Appearance** | blur, dimming, card shape and size, corner radius, side card darkening, ring spacing and radius, number of visible cards, animation speed, spin-in, search bar and hints; reset to defaults and a live preview button |

By default the launcher reads `~/Pictures/Wallpaper`.

### Scripting

```bash
open -a WallpaperLauncher                                               # toggle the launcher (e.g. from skhd or Hammerspoon)
~/Applications/WallpaperLauncher.app/Contents/MacOS/WallpaperLauncher --random      # set a random wallpaper and exit
~/Applications/WallpaperLauncher.app/Contents/MacOS/WallpaperLauncher --background  # start without showing the panel
```

## Notes

- macOS only changes the wallpaper of the **current Space**; this is a limitation of the system API.
- The light background blur uses a private window server call (the same one terminal emulators use). If it ever becomes unavailable, the app falls back to a standard macOS blur.
- "Launch at Login" requires the app to live in `/Applications` or `~/Applications`.

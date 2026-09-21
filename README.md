<p align="center">
  <img src="Resources/Transom.png" alt="Transom logo" width="160" height="160">
</p>

# Transom

Transom is a native macOS browser-profile shell and web-link router. It
groups windows from the same browser into a profile-oriented stack, adds
a glass tab strip above the browser, and keeps grouped windows together
when moved or resized.

## Supported browsers

Transom discovers installed macOS versions of:

- Google Chrome
- Microsoft Edge
- Brave
- Vivaldi
- Opera
- Arc
- Chromium
- Helium
- Firefox
- Zen

Chromium-family profiles are read from `Local State`. Firefox and Zen
profiles are read from `profiles.ini`. Transom resolves profiles from
window titles and process arguments, retaining validated per-window
assignments while windows remain open. Ambiguous multi-profile Chromium
windows remain unidentified rather than being assigned the wrong
profile.

## Window overlay

- one independent glass container per running browser
- native AppKit segmented tabs with profile-colored indicators
- stable tab order while native window stacking changes
- exact-window switching through Accessibility APIs
- synchronized movement and resizing for grouped windows
- normal macOS window layering, spaces, and fullscreen support
- menu-bar accessory operation with no Dock icon

macOS does not allow one application to re-parent another application's
`NSWindow`. Transom creates the container illusion by aligning native
browser windows and synchronizing them through the Accessibility API.

## Web-link routing

Transom registers `http` and `https` handlers and can be selected as the
default browser from its menu-bar menu.

Unmatched links open a Spotlight-style profile picker with:

- browser and profile search
- keyboard navigation and Return/Escape handling
- browser icons and profile colors
- saved destinations for an entire site, a path and its subpaths, or an
  exact path, including custom paths

The **Links** section in Settings supports mappings using:

- host globs such as `*.example.com`
- host-scoped path prefixes and exact paths
- path regular expressions
- complete URL regular expressions

Regex rules take priority in list order. Site rules prefer the most
specific matching path. Hold Option when opening a link to bypass
automatic routing and choose a profile once.

Rules are stored at:

```text
~/Library/Application Support/Transom/routing.json
```

## Settings and themes

Open **Settings…** from the menu bar or the overlay’s native
right-click menu. Settings include launch-at-login, window-manager
compatibility, browser discovery, link routing, and overlay themes.
Themes include Automatic, Light, Black, and all four Catppuccin flavors:
Latte, Frappé, Macchiato, and Mocha. The URL opener follows the selected
theme. Profile names and colors can be customized in **Browsers**.

## Run

```bash
mise run run
```

On first launch, grant Transom access in **System Settings → Privacy &
Security → Accessibility**. Reopen Transom after granting access if the
overlay does not appear immediately.

To run checks:

```bash
mise run check
mise run test
```

The built application is written to `.build/Transom.app`.

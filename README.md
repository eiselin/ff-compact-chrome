# ff-chrome

macOS vibrancy, rounded content card, floating URL bar, and compact vertical tabs for Firefox and LibreWolf.

## What it does

- **Full-window frosted glass** via macOS vibrancy
- **Sidebar as a rounded pill** — semi-transparent, with drop shadow
- **Compact sidebar mode** — hides the sidebar; it reappears as an overlay when you move the cursor to the left edge of the window
- **Floating URL bar** — hidden by default, appears centred on screen when you press Cmd+L
- **Content as a rounded card** — the web page sits in a pill with rounded corners and a drop shadow
- Removes bookmarks bar, sponsored content, and other clutter

## Requirements

- macOS
- Firefox 130+ or LibreWolf (latest)
- The browser must have been opened at least once to create a profile

## Installation

```bash
git clone <repo-url>
cd <repo>
./patch.sh [firefox|librewolf]
```

Omit the browser argument to patch all installed browsers automatically. The script will ask for your password to modify the app bundle.

**Restart the browser after patching.**

## Updating

Pull and re-run. CSS files are always overwritten; the `user.js` block and AutoConfig JS are only added if not already present.

```bash
git pull
./patch.sh [firefox|librewolf]
```

## Uninstalling

```bash
./unpatch.sh [firefox|librewolf]
```

Removes all changes: AutoConfig JS from the app bundle, the `user.js` prefs block, and all CSS files from the profile. Restart the browser afterwards.

## Shortcuts

| Action | Shortcut |
|---|---|
| Toggle compact sidebar | `Ctrl+Shift+A` |
| Open URL bar | `Cmd+L` |

## How it works

Three layers work together:

**`userChrome.css` + `compact.css`** — all visual styling. Reacts to `[compact-sidebar]` and `[sidebar-hover]` attributes on `:root` that the JS sets.

**AutoConfig JS** (injected into the app bundle) — runs privileged JS in the browser chrome. Handles the `Ctrl+Shift+A` keyboard shortcut, persists the sidebar state across restarts, and creates a 20px invisible hover zone at the left window edge that CSS alone cannot detect (CSS `:hover` fails over display:none elements and out-of-process iframe content).

**`user.js`** — browser preferences. Enables `userChrome.css` loading (`toolkit.legacyUserProfileCustomizations.stylesheets`) and macOS vibrancy (`widget.macos.titlebar-blend-mode.behind-window`). Without these two prefs nothing works.

## No-patch fallback (Gatekeeper / SIP machines)

On machines where the app bundle cannot be modified, skip `patch.sh` and instead: raname fallbackUserChrome.css to userChrome.css and place that in the chrome folder of your profile.

`fallbackUserChrome.css` applies the same glass pill to the sidebar but leaves Firefox's built-in expand/collapse in control of the width. Compact overlay mode (`Ctrl+Shift+A` / hover zone) is not available — use the sidebar's own toggle button instead.

## Files

| File | Purpose |
|---|---|
| `userChrome.css` | Main stylesheet — layout, vibrancy, URL bar, content card |
| `compact.css` | Sidebar pill rules with compact overlay mode (requires patch) |
| `fallbackUserChrome.css` | Sidebar pill rules without compact mode (no patch required) |
| `patch.sh` | Installer |
| `unpatch.sh` | Uninstaller |

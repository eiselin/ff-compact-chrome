#!/usr/bin/env bash
# patch.sh — Firefox 130+ / LibreWolf macOS chrome patcher
# Usage: ./patch.sh [firefox|librewolf]   (default: patch all installed browsers)
# Idempotent: safe to run multiple times. CSS files are always overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { echo "▸ $*"; }
warn() { echo "⚠ $*" >&2; }
die()  { echo "✗ $*" >&2; exit 1; }

# ── browser selection ─────────────────────────────────────────────────────────

case "${1:-}" in
  firefox|Firefox)     APP_PATHS=(/Applications/Firefox.app) ;;
  librewolf|LibreWolf) APP_PATHS=(/Applications/LibreWolf.app) ;;
  "")                  APP_PATHS=(/Applications/Firefox.app /Applications/LibreWolf.app) ;;
  *) die "Unknown browser '${1}'. Use: firefox, librewolf, or omit to auto-detect." ;;
esac

# ── verify source files ───────────────────────────────────────────────────────

[[ -f "$SCRIPT_DIR/userChrome.css" ]] || die "userChrome.css not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_DIR/compact.css" ]]    || die "compact.css not found in $SCRIPT_DIR"

# ── profile finder ────────────────────────────────────────────────────────────

find_profile() {
  local ini="$1" base_dir
  base_dir="$(dirname "$ini")"

  # Modern Firefox/LibreWolf profiles.ini uses [Install<hash>] sections with
  # Default=<relative-path> rather than Default=1 inside [Profile] sections.
  # Try the [Install] format first, then fall back to the legacy Default=1 flag.

  local result
  result="$(awk -F= '
    /^\[Install/  { in_install=1 }
    /^\[/         { if (!/^\[Install/) in_install=0 }
    in_install && /^Default=/ { print "1:" $2; exit }
  ' "$ini")"

  if [[ -z "$result" ]]; then
    # Legacy format: Default=1 flag inside a [Profile] section
    result="$(awk -F= '
      /^\[Profile/ { path=""; is_default=0; is_relative=1 }
      /^Path=/      { path=$2 }
      /^IsRelative=/ { is_relative=$2 }
      /^Default=1/  { is_default=1 }
      /^$/          { if (is_default && path) { print is_relative ":" path; exit } }
      END           { if (is_default && path) print is_relative ":" path }
    ' "$ini")"
  fi

  [[ -z "$result" ]] && return

  IFS=: read -r rel p <<< "$result"
  if [[ "$rel" == "1" ]]; then echo "$base_dir/$p"; else echo "$p"; fi
}

# Append content to file only if marker string is absent (idempotent).
append_if_missing() {
  local file="$1" marker="$2" content="$3"
  if grep -qF "$marker" "$file" 2>/dev/null; then
    log "  already patched: $(basename "$file")"
  else
    printf '\n%s\n' "$content" >> "$file"
    log "  patched: $(basename "$file")"
  fi
}

# ── AutoConfig JS ─────────────────────────────────────────────────────────────
# Injected into librewolf.cfg (LibreWolf) or ff-patch.cfg (Firefox).
# Provides: Ctrl+Shift+A compact-sidebar toggle, state persistence, hover zone.

read -r -d '' AUTOCONFIG_JS << 'JSEOF' || true
// ff-patch: compact sidebar ───────────────────────────────────────────────
(function ffPatch() {
  "use strict";

  var COMPACT_PREF = "userchrome.compact.mode";

  function setupWindow(domWin) {
    var doc = domWin.document;
    if (!doc || doc.documentElement.getAttribute("windowtype") !== "navigator:browser") return;

    var html = doc.documentElement;

    // Restore compact state from last session
    try {
      if (Services.prefs.getBoolPref(COMPACT_PREF, false)) {
        html.setAttribute("compact-sidebar", "");
      }
    } catch (_) {}

    // Ctrl+Shift+A → toggle compact sidebar
    doc.addEventListener("keydown", function(e) {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === "A" && !e.altKey) {
        if (html.hasAttribute("compact-sidebar")) {
          html.removeAttribute("compact-sidebar");
          html.removeAttribute("sidebar-hover");
          Services.prefs.setBoolPref(COMPACT_PREF, false);
        } else {
          html.setAttribute("compact-sidebar", "");
          Services.prefs.setBoolPref(COMPACT_PREF, true);
        }
        e.preventDefault();
        e.stopPropagation();
      }
    }, true);

    // 20px invisible zone at left edge: reliable hover trigger over OOP frames.
    // CSS :hover fails when the sidebar is display:none or over iframe content.
    if (!doc.getElementById("compact-sidebar-zone")) {
      var zone = doc.createElementNS("http://www.w3.org/1999/xhtml", "div");
      zone.id = "compact-sidebar-zone";
      zone.setAttribute("style",
        "position:fixed;left:0;top:0;width:20px;height:100%;z-index:9999;" +
        "pointer-events:none;background:transparent;");
      var zoneRoot = doc.getElementById("browser-panel") ||
                     doc.getElementById("main-window") ||
                     doc.documentElement;
      zoneRoot.appendChild(zone);

      function refreshZone() {
        zone.style.pointerEvents =
          (html.hasAttribute("compact-sidebar") && !html.hasAttribute("sidebar-hover"))
            ? "auto" : "none";
      }

      zone.addEventListener("mouseenter", function() {
        if (!html.hasAttribute("compact-sidebar")) return;
        html.setAttribute("sidebar-hover", "");
        refreshZone();
      });

      var sidebarMain = doc.getElementById("sidebar-main");
      if (sidebarMain) {
        sidebarMain.addEventListener("mouseleave", function() {
          html.removeAttribute("sidebar-hover");
          refreshZone();
        });
      }

      new doc.defaultView.MutationObserver(refreshZone)
        .observe(html, { attributes: true,
                         attributeFilter: ["compact-sidebar", "sidebar-hover"] });
      refreshZone();
    }
  }

  var en = Services.wm.getEnumerator("navigator:browser");
  while (en.hasMoreElements()) {
    setupWindow(en.getNext().QueryInterface(Ci.nsIDOMWindow));
  }

  Services.wm.addListener({
    onOpenWindow: function(xulWin) {
      var w = xulWin.QueryInterface(Ci.nsIInterfaceRequestor).getInterface(Ci.nsIDOMWindow);
      w.addEventListener("load", function() { setupWindow(w); }, { once: true });
    },
    onCloseWindow: function() {},
    onWindowTitleChange: function() {}
  });
}());
// ff-patch end ───────────────────────────────────────────────────────────────
JSEOF

# ── user.js prefs ─────────────────────────────────────────────────────────────

read -r -d '' USERJS_BLOCK << 'PREFEOF' || true
// ff-patch: user.js ──────────────────────────────────────────────────────────

// Enable userChrome.css / userContent.css
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// macOS vibrancy
user_pref("widget.macos.titlebar-blend-mode.behind-window", true);

// Remove fullscreen overlay warning
user_pref("full-screen-api.warning.timeout", 0);

// New tab cleanup
user_pref("browser.newtabpage.activity-stream.showSponsored",              false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites",      false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites",             false);
user_pref("browser.newtabpage.activity-stream.feeds.section.highlights",   false);

// URL bar
user_pref("browser.urlbar.suggest.topsites", false);
user_pref("browser.urlbar.trimURLs",         true);

// Session restore on startup
user_pref("browser.startup.page",                   3);
user_pref("browser.sessionstore.restore_on_demand", true);

// Smooth scrolling
user_pref("general.smoothScroll",                              true);
user_pref("general.smoothScroll.currentVelocityWeighting",    "0.1");
user_pref("general.smoothScroll.stopDecelerationWeighting",    "0.8");
user_pref("mousewheel.acceleration.factor",                    10);
user_pref("mousewheel.acceleration.start",                     -1);

// Privacy
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("browser.discovery.enabled",               false);

// Bookmarks bar — keep hidden
user_pref("browser.toolbars.bookmarks.visibility", "never");

// ff-patch end ───────────────────────────────────────────────────────────────
PREFEOF

# ── patch app bundle ──────────────────────────────────────────────────────────

patch_app() {
  local app_name="$1" app_path="$2"
  local res="$app_path/Contents/Resources"

  log ""
  log "=== $app_name ==="

  if [[ "$app_name" == "LibreWolf" ]]; then
    local cfg="$res/librewolf.cfg"
    [[ -f "$cfg" ]] || die "Expected $cfg to exist."
    append_if_missing "$cfg" "// ff-patch: compact sidebar" "$AUTOCONFIG_JS"

  else
    # Firefox: create an autoconfig pointer file, then write the cfg.
    local pref_dir="$res/defaults/pref"
    mkdir -p "$pref_dir"

    local pref_file="$pref_dir/ff-autoconfig.js"
    if [[ ! -f "$pref_file" ]]; then
      cat > "$pref_file" << 'PEOF'
// ff-patch autoconfig pointer (do not edit — managed by patch.sh)
pref("general.config.filename",        "ff-patch.cfg");
pref("general.config.obscure_value",   0);
pref("general.config.sandbox_enabled", false);
PEOF
      log "  created: $pref_file"
    else
      log "  already exists: $(basename "$pref_file")"
    fi

    local cfg_file="$res/ff-patch.cfg"
    if [[ ! -f "$cfg_file" ]]; then
      # Firefox autoconfig files must start with a comment or null; on line 1.
      printf 'null;\n%s\n' "$AUTOCONFIG_JS" > "$cfg_file"
      log "  created: $cfg_file"
    else
      append_if_missing "$cfg_file" "// ff-patch: compact sidebar" "$AUTOCONFIG_JS"
    fi
  fi
}

# ── patch profile ─────────────────────────────────────────────────────────────

patch_profile() {
  local profile_dir="$1"
  [[ -d "$profile_dir" ]] || { warn "Profile not found: $profile_dir"; return; }

  log ""
  log "--- profile: $profile_dir"

  # user.js — append prefs block if not already present
  local userjs="$profile_dir/user.js"
  touch "$userjs"
  append_if_missing "$userjs" "// ff-patch: user.js" "$USERJS_BLOCK"

  # chrome directory
  local chrome_dir="$profile_dir/chrome"
  mkdir -p "$chrome_dir"

  # CSS files — always overwritten so updates are picked up on re-run
  cp "$SCRIPT_DIR/userChrome.css" "$chrome_dir/userChrome.css"
  log "  wrote: userChrome.css"

  cp "$SCRIPT_DIR/compact.css" "$chrome_dir/compact.css"
  log "  wrote: compact.css"

  # Safety: ensure @import is present (it already is in our userChrome.css,
  # but guard against it being stripped somehow)
  if ! grep -qF "compact.css" "$chrome_dir/userChrome.css"; then
    local tmp; tmp="$(mktemp)"
    { printf '@import url("compact.css");\n\n'; cat "$chrome_dir/userChrome.css"; } > "$tmp"
    mv "$tmp" "$chrome_dir/userChrome.css"
    log "  added @import to userChrome.css"
  fi
}

# ── sudo escalation ───────────────────────────────────────────────────────────

for app_path in "${APP_PATHS[@]}"; do
  [[ -d "$app_path" ]] || continue
  if [[ ! -w "$app_path/Contents/Resources" ]] && [[ "$(id -u)" -ne 0 ]]; then
    log "App bundle not writable — re-launching with sudo..."
    exec sudo bash "$0" "$@"
  fi
done

# ── main ──────────────────────────────────────────────────────────────────────

found=false

for app_path in "${APP_PATHS[@]}"; do
  [[ -d "$app_path" ]] || continue
  found=true

  app_name="$(basename "$app_path" .app)"
  patch_app "$app_name" "$app_path"

  case "$app_name" in
    Firefox)   support="$HOME/Library/Application Support/Firefox" ;;
    LibreWolf) support="$HOME/Library/Application Support/librewolf" ;;
    *) continue ;;
  esac

  ini="$support/profiles.ini"
  if [[ ! -f "$ini" ]]; then
    warn "profiles.ini not found: $ini"
    continue
  fi

  profile="$(find_profile "$ini")"
  if [[ -z "$profile" ]]; then
    warn "Could not determine active profile from $ini"
    continue
  fi

  patch_profile "$profile"
done

$found || die "No target browser found. Looked for: ${APP_PATHS[*]}"

log ""
log "Done. Restart the browser for all changes to take effect."
log "Compact sidebar: Ctrl+Shift+A  |  URL bar: Cmd+L"

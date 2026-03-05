#!/usr/bin/env bash
# unpatch.sh — Undo everything patch.sh applied.
# Usage: ./unpatch.sh [firefox|librewolf]   (default: unpatch all installed browsers)
# Idempotent: safe to run multiple times.
set -euo pipefail

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

# ── profile finder (identical to patch.sh) ────────────────────────────────────

find_profile() {
  local ini="$1" base_dir
  base_dir="$(dirname "$ini")"
  awk -F= '
    /^\[Profile/   { path=""; is_default=0; is_relative=1 }
    /^Path=/       { path=$2 }
    /^IsRelative=/ { is_relative=$2 }
    /^Default=1/   { is_default=1 }
    /^$/           { if (is_default && path) { print is_relative ":" path; exit } }
  ' "$ini" | {
    IFS=: read -r rel p
    if [[ "$rel" == "1" ]]; then echo "$base_dir/$p"; else echo "$p"; fi
  }
}

# Write tmp file back to dest; fall back to sudo tee if not writable.
write_back() {
  local dest="$1" tmp="$2"
  if mv "$tmp" "$dest" 2>/dev/null; then
    :
  else
    sudo tee "$dest" < "$tmp" > /dev/null
    rm -f "$tmp"
  fi
}

# Remove lines from start_marker through end_marker (both inclusive).
# Uses plain substring matching — safe against regex special characters.
remove_block() {
  local file="$1" start="$2" end="$3"
  [[ -f "$file" ]] || { log "  skip (not found): $(basename "$file")"; return; }
  if ! grep -qF "$start" "$file"; then
    log "  already clean: $(basename "$file")"; return
  fi
  local tmp; tmp="$(mktemp)"
  awk -v s="$start" -v e="$end" '
    index($0, s) { skip=1 }
    !skip        { print }
    skip && index($0, e) { skip=0 }
  ' "$file" > "$tmp"
  write_back "$file" "$tmp"
  log "  removed block from $(basename "$file")"
}

# Remove every line containing pattern (plain substring match).
remove_lines() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] || { log "  skip (not found): $(basename "$file")"; return; }
  if ! grep -qF "$pattern" "$file"; then
    log "  already clean: $(basename "$file")"; return
  fi
  local tmp; tmp="$(mktemp)"
  grep -vF "$pattern" "$file" > "$tmp" || true
  write_back "$file" "$tmp"
  log "  removed lines matching '$pattern' from $(basename "$file")"
}

# Remove a file, using sudo if necessary.
remove_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    rm "$f" 2>/dev/null || sudo rm "$f"
    log "  removed: $(basename "$f")"
  else
    log "  not found: $(basename "$f")"
  fi
}

# ── sudo escalation ───────────────────────────────────────────────────────────

# Recover the real user's home when re-launched via sudo.
if [[ -n "${SUDO_USER:-}" ]]; then
  REAL_HOME=$(eval echo "~$SUDO_USER")
else
  REAL_HOME="$HOME"
fi

for app_path in "${APP_PATHS[@]}"; do
  [[ -d "$app_path" ]] || continue
  if [[ ! -w "$app_path/Contents/Resources" ]] && [[ "$(id -u)" -ne 0 ]]; then
    log "App bundle not writable — re-launching with sudo..."
    exec sudo bash "$0" "$@"
  fi
done

# ── unpatch app bundles ───────────────────────────────────────────────────────

found=false

for app_path in "${APP_PATHS[@]}"; do
  [[ -d "$app_path" ]] || continue
  found=true
  app_name="$(basename "$app_path" .app)"
  res="$app_path/Contents/Resources"

  log ""
  log "=== $app_name ==="

  if [[ "$app_name" == "LibreWolf" ]]; then
    cfg="$res/librewolf.cfg"
    remove_block "$cfg" "// ff-patch: compact sidebar"  "// ff-patch end"
    remove_block "$cfg" "// ff-patch2: compact sidebar hover zone" "// ff-patch2 end"
  else
    remove_file "$res/defaults/pref/ff-autoconfig.js"
    remove_file "$res/ff-patch.cfg"
  fi
done

$found || die "No target browser found. Looked for: ${APP_PATHS[*]}"

# ── unpatch profiles ──────────────────────────────────────────────────────────

for app_path in "${APP_PATHS[@]}"; do
  [[ -d "$app_path" ]] || continue
  app_name="$(basename "$app_path" .app)"

  case "$app_name" in
    Firefox)   support="$REAL_HOME/Library/Application Support/Firefox" ;;
    LibreWolf) support="$REAL_HOME/Library/Application Support/librewolf" ;;
    *) continue ;;
  esac

  ini="$support/profiles.ini"
  if [[ ! -f "$ini" ]]; then warn "profiles.ini not found: $ini"; continue; fi

  profile="$(find_profile "$ini")"
  if [[ -z "$profile" ]]; then warn "Could not determine active profile from $ini"; continue; fi

  log ""
  log "--- profile: $profile"

  chrome="$profile/chrome"

  remove_block "$profile/user.js" "// ff-patch: user.js" "// ff-patch end"
  remove_file  "$chrome/userChrome.css"
  remove_file  "$chrome/compact.css"
  remove_file  "$chrome/hover-patch.js"
done

log ""
log "Done. Restart the browser to restore default behaviour."

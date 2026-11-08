#!/usr/bin/env bash
# cleanup-fedora.sh
# Removes unused dependencies, package caches, unused Flatpak runtimes,
# old journal logs, thumbnail cache and (after confirmation) the Trash.
# Package removals show the list and ask before anything is deleted.
# App data, browser profiles and ~/.var are never touched.

set -uo pipefail

# --- Open in a terminal if not already running in one ------------------------
if [[ ! -t 1 ]]; then
  script="$(readlink -f "$0")"
  if command -v konsole >/dev/null 2>&1; then
    exec konsole -e bash "$script"
  elif command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- bash "$script"
  elif command -v xfce4-terminal >/dev/null 2>&1; then
    exec xfce4-terminal -e "bash '$script'"
  elif command -v xterm >/dev/null 2>&1; then
    exec xterm -e bash "$script"
  else
    echo "No terminal emulator found." >&2
    exit 1
  fi
fi

bold() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

failed=()

# run <label> <command...>
run() {
  local label="$1"; shift
  bold "$label"
  "$@"
  local rc=$?
  if (( rc == 0 )); then
    echo "[done] $label"
  else
    echo "[failed] $label (exit $rc)"
    failed+=("$label")
  fi
}

echo "Disk usage on / before cleanup:"
df -h / | tail -1

# --- 1. Packages (dnf) --------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
  # Unused dependencies. dnf lists them and asks before removing.
  run "Unused dependencies" sudo dnf autoremove

  # Cached packages and metadata. Re-downloaded automatically when needed.
  run "DNF cache" sudo dnf clean all
fi

# --- 2. Flatpak --------------------------------------------------------------
if command -v flatpak >/dev/null 2>&1; then
  # Runtimes and extensions no installed app depends on. Lists them and asks first.
  run "Unused Flatpak runtimes" flatpak uninstall --unused
fi

# --- 3. Journal logs ----------------------------------------------------------
if command -v journalctl >/dev/null 2>&1; then
  run "Journal logs older than 2 weeks" sudo journalctl --vacuum-time=2weeks
fi

# --- 4. Thumbnail cache -------------------------------------------------------
if [[ -d "$HOME/.cache/thumbnails" ]]; then
  run "Thumbnail cache" rm -rf -- "$HOME/.cache/thumbnails"
fi

# --- 5. Trash (asks first, deletion is permanent) ----------------------------
trash_dir="$HOME/.local/share/Trash"
if [[ -n "$(ls -A "$trash_dir/files" 2>/dev/null)" ]]; then
  echo
  read -rp "Permanently empty the Trash? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    run "Trash" find "$trash_dir/files" "$trash_dir/info" -mindepth 1 -delete
  else
    echo "Trash kept."
  fi
fi

# --- Summary ------------------------------------------------------------------
bold "Summary"
echo "Disk usage on / after cleanup:"
df -h / | tail -1
echo
if (( ${#failed[@]} == 0 )); then
  echo "Cleanup finished."
else
  echo "Finished with errors in: ${failed[*]}"
fi

echo
read -rp "Press Enter to close..." _

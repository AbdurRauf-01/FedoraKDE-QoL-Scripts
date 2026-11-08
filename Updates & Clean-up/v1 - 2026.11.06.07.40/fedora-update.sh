#!/usr/bin/env bash
# fedora-update.sh
# Updates system packages, Flatpak apps and firmware on Fedora, similar to Discover.
# Does NOT upgrade the Fedora release (e.g. 44 -> 45).
# Opens a terminal window automatically when launched from a menu or file manager.

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

# --- Firmware (fwupd) ---------------------------------------------------------
firmware_update() {
  sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
  sudo fwupdmgr update
  local rc=$?
  # fwupdmgr exits with 2 when there is nothing to update
  if (( rc == 2 )); then
    echo "No firmware updates available."
    return 0
  fi
  return $rc
}

# --- 1. System packages (dnf) -------------------------------------------------
# "dnf upgrade" only applies updates within the current release.
# Release upgrades would require "dnf system-upgrade", which this script never runs.
if command -v dnf >/dev/null 2>&1; then
  run "System packages" sudo dnf upgrade --refresh
fi

# --- 2. Flatpak apps ----------------------------------------------------------
if command -v flatpak >/dev/null 2>&1; then
  run "Flatpak apps" flatpak update
fi

# --- 3. Firmware --------------------------------------------------------------
if command -v fwupdmgr >/dev/null 2>&1; then
  run "Firmware" firmware_update
fi

# --- Summary ------------------------------------------------------------------
bold "Summary"
if (( ${#failed[@]} == 0 )); then
  echo "All updates finished."
else
  echo "Finished with errors in: ${failed[*]}"
fi

# Reboot check (dnf-plugins-core: needs-restarting -r exits 1 when a reboot is needed)
if command -v dnf >/dev/null 2>&1; then
  if ! sudo dnf needs-restarting -r >/dev/null 2>&1; then
    echo "A reboot is required to finish the updates."
  fi
fi

echo
read -rp "Press Enter to close..." _

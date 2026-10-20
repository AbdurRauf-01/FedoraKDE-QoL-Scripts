#!/usr/bin/env bash
# Fully stop Waydroid: session, then container.
# Double-click: GUI dialogs (kdialog, or zenity as fallback) + password prompt (pkexec).
# Terminal:     ./waydroid-close.sh

set -uo pipefail
SELF="$(readlink -f "$0")"
TITLE="Close Waydroid"

# ---------- privileged part (runs as root) ----------
if [[ $EUID -eq 0 ]]; then
    systemctl stop waydroid-container || { echo "Failed to stop waydroid-container."; exit 1; }
    # Clean up leftover session process if any
    pkill -f "waydroid session start" 2>/dev/null
    echo "Waydroid stopped."
    exit 0
fi

# ---------- user part (dialogs) ----------
[[ -t 0 ]] && TERMINAL_MODE=1 || TERMINAL_MODE=""

show() {  # $1 = text, $2 = info|error
    if [[ -n "$TERMINAL_MODE" ]]; then
        echo "$1"
    elif command -v kdialog >/dev/null 2>&1; then
        if [[ "$2" == "error" ]]; then kdialog --title "$TITLE" --error "$1"
        else kdialog --title "$TITLE" --msgbox "$1"; fi
    elif command -v zenity >/dev/null 2>&1; then
        zenity --"$2" --title "$TITLE" --text "$1"
    fi
}

# Session runs as the user, so stop it before escalating
[[ -n "$TERMINAL_MODE" ]] && echo "Stopping session..."
waydroid session stop >/dev/null 2>&1

[[ -n "$TERMINAL_MODE" ]] && echo "Stopping container..."
if [[ -n "$TERMINAL_MODE" ]]; then
    out="$(sudo bash "$SELF" 2>&1)"; rc=$?
else
    out="$(pkexec bash "$SELF" 2>&1)"; rc=$?
fi

if [[ $rc -eq 0 ]]; then
    show "$out" info
elif [[ $rc -eq 126 || $rc -eq 127 ]]; then
    show "Authentication cancelled or failed. Container may still be running." error
else
    show "${out:-Something went wrong.}" error
fi

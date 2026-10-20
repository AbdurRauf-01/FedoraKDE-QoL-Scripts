#!/usr/bin/env bash
# Schedule a one-time graceful shutdown after N minutes (ignores inhibitor locks).
# Double-click: GUI dialogs (kdialog, or zenity as fallback).
# Terminal:     ./shutdown-in.sh [minutes]

set -uo pipefail
SELF="$(readlink -f "$0")"
TITLE="Auto Shutdown"

# ---------- privileged part (runs as root) ----------
if [[ $EUID -eq 0 ]]; then
    mins="$1"
    command -v at >/dev/null 2>&1 || { echo "'at' is not installed. Run: sudo dnf install at"; exit 1; }
    systemctl enable --now atd >/dev/null 2>&1 || true
    if echo "systemctl poweroff -i" | at now + "$mins" minutes >/dev/null 2>&1; then
        echo "Shutdown scheduled for $(date -d "+$mins minutes" '+%H:%M:%S on %Y-%m-%d')."
        exit 0
    fi
    echo "Failed to schedule the shutdown."
    exit 1
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

ask() {
    if [[ -n "$TERMINAL_MODE" ]]; then
        read -rp "Shutdown in how many minutes? " REPLY; echo "$REPLY"
    elif command -v kdialog >/dev/null 2>&1; then
        kdialog --title "$TITLE" --inputbox "Shutdown in how many minutes?" 30
    elif command -v zenity >/dev/null 2>&1; then
        zenity --entry --title "$TITLE" --text "Shutdown in how many minutes?" --entry-text 30
    else
        echo "No dialog tool found (install kdialog or zenity)." >&2; exit 1
    fi
}

mins="${1:-}"
if [[ -z "$mins" ]]; then
    mins="$(ask)" || exit 0          # dialog cancelled
fi

if ! [[ "$mins" =~ ^[1-9][0-9]*$ ]]; then
    show "Invalid input. Enter a positive whole number of minutes." error
    exit 1
fi

if [[ -n "$TERMINAL_MODE" ]]; then
    out="$(sudo bash "$SELF" "$mins" 2>&1)"; rc=$?
else
    out="$(pkexec bash "$SELF" "$mins" 2>&1)"; rc=$?
fi

if [[ $rc -eq 0 ]]; then
    show "$out" info
elif [[ $rc -eq 126 || $rc -eq 127 ]]; then
    show "Authentication cancelled or failed. Nothing was scheduled." error
else
    show "${out:-Something went wrong.}" error
fi

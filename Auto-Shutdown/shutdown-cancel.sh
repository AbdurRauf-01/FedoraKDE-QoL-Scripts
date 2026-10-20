#!/usr/bin/env bash
# Cancel all scheduled shutdowns ('at' poweroff jobs and 'shutdown' schedules).
# Double-click: GUI dialogs (kdialog, or zenity as fallback).
# Terminal:     ./cancel-shutdown.sh

set -uo pipefail
SELF="$(readlink -f "$0")"
TITLE="Cancel Shutdown"

# ---------- privileged part (runs as root) ----------
if [[ $EUID -eq 0 ]]; then
    removed=0
    if command -v atq >/dev/null 2>&1; then
        for id in $(atq | awk '{print $1}'); do
            if at -c "$id" 2>/dev/null | grep -qE 'systemctl (poweroff|halt)|shutdown'; then
                atrm "$id" && removed=$((removed + 1))
            fi
        done
    fi
    extra=""
    if shutdown -c 2>/dev/null; then extra=" Also cancelled a pending 'shutdown' schedule."; fi
    echo "Removed $removed scheduled shutdown job(s).$extra"
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

if [[ -n "$TERMINAL_MODE" ]]; then
    out="$(sudo bash "$SELF" 2>&1)"; rc=$?
else
    out="$(pkexec bash "$SELF" 2>&1)"; rc=$?
fi

if [[ $rc -eq 0 ]]; then
    show "$out" info
elif [[ $rc -eq 126 || $rc -eq 127 ]]; then
    show "Authentication cancelled or failed. Nothing was cancelled." error
else
    show "${out:-Something went wrong.}" error
fi

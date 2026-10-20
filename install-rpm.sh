#!/usr/bin/env bash
# GUI RPM installer for Fedora (requires zenity, preinstalled on Fedora Workstation)
# Flow: browse for .rpm -> sudo password prompt -> progress window -> success/failure dialog

set -u
TITLE="RPM Installer"

if ! command -v zenity >/dev/null 2>&1; then
    echo "zenity not found. Install it with: sudo dnf install zenity" >&2
    exit 1
fi

# 1. File picker
RPM_FILE=$(zenity --file-selection \
    --title="$TITLE - Select an RPM package" \
    --filename="$HOME/Downloads/" \
    --file-filter="RPM packages | *.rpm" \
    --file-filter="All files | *") || exit 0

if [[ ! -f "$RPM_FILE" || "$RPM_FILE" != *.rpm ]]; then
    zenity --error --title="$TITLE" --text="Not a valid .rpm file:\n$RPM_FILE"
    exit 1
fi

# 2. Password prompt (passed to sudo via stdin, never on the command line)
PASS=$(zenity --password --title="$TITLE - Authentication required") || exit 0

if ! printf '%s\n' "$PASS" | sudo -S -p '' -v 2>/dev/null; then
    zenity --error --title="$TITLE" --text="Authentication failed. Wrong password or no sudo rights."
    unset PASS
    exit 1
fi

# 3. Install with progress window
LOG=$(mktemp /tmp/rpm-install.XXXXXX.log)
STATUS_FILE=$(mktemp)

{
    echo "# Installing $(basename "$RPM_FILE")..."
    printf '%s\n' "$PASS" | sudo -S -p '' dnf install -y "$RPM_FILE" 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$LOG"
        clean=${line##*$'\r'}
        [[ -n "${clean// /}" ]] && echo "# ${clean:0:100}"
    done
    echo "${PIPESTATUS[1]}" > "$STATUS_FILE"
} | zenity --progress --pulsate --auto-close --no-cancel \
    --title="$TITLE" --text="Starting..." --width=500

unset PASS
sudo -k 2>/dev/null

# 4. Result
RC=$(cat "$STATUS_FILE" 2>/dev/null || echo 1)
rm -f "$STATUS_FILE"

if [[ "$RC" == "0" ]]; then
    zenity --info --title="$TITLE" --text="Install successful:\n$(basename "$RPM_FILE")" --width=350
else
    zenity --text-info --title="$TITLE - Install failed (exit code $RC)" \
        --filename="$LOG" --width=700 --height=450
    exit 1
fi

#!/usr/bin/env bash
# Creates a store-only RAR with a 20% recovery record, BLAKE2 checksums,
# and encrypted headers. Folder selection uses KDE dialogs; rar runs in Konsole
# and prompts for the password there.

command -v rar >/dev/null || { echo "rar not found in PATH"; exit 1; }
command -v kdialog >/dev/null || { echo "kdialog not found. Install it with: sudo dnf install kdialog"; exit 1; }
command -v konsole >/dev/null || { echo "konsole not found. Install it with: sudo dnf install konsole"; exit 1; }

# 1. Select one or more folders
FOLDERS=()
while true; do
    dir=$(kdialog --title "Select folder to archive" --getexistingdirectory "$HOME") || break
    FOLDERS+=("$dir")
    kdialog --title "Folders selected: ${#FOLDERS[@]}" \
            --yesno "Added:\n$dir\n\nAdd another folder?" || break
done
[ ${#FOLDERS[@]} -eq 0 ] && exit 0

# 2. Choose archive name and location
ARCHIVE=$(kdialog --title "Save archive as" --getsavefilename "$HOME/Archive.rar" "*.rar") || exit 0
[[ "$ARCHIVE" == *.rar ]] || ARCHIVE="$ARCHIVE.rar"

if [ -e "$ARCHIVE" ]; then
    kdialog --warningyesno "$ARCHIVE already exists.\nOverwrite it?" || exit 0
    rm -f -- "$ARCHIVE"
fi

# 3. Build the command to run inside Konsole, quoting each path safely
cmd=$(printf 'rar a -m0 -rr20 -htb -hp %q' "$ARCHIVE")
for f in "${FOLDERS[@]}"; do
    cmd+=$(printf ' %q' "$f")
done
cmd+='; rc=$?; echo; if [ $rc -eq 0 ]; then echo "Archive created: '
cmd+=$(printf '%q' "$ARCHIVE")
cmd+='"; else echo "rar failed (exit $rc)"; fi'

# 4. Run rar in Konsole. --hold keeps the window open after rar finishes.
konsole --hold -e bash -c "$cmd"

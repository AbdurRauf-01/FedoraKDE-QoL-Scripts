#!/usr/bin/env bash
# Creates a store-only RAR with a 20% recovery record, BLAKE2 checksums,
# and encrypted headers. Folder selection uses KDE dialogs; rar runs in Konsole
# and prompts for the password there. Stored paths are relative to the parent folder.

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

# 2. All folders must share one parent so rar can store bare folder names
PARENT=$(dirname -- "${FOLDERS[0]}")
NAMES=()
for f in "${FOLDERS[@]}"; do
    if [ "$(dirname -- "$f")" != "$PARENT" ]; then
        kdialog --error "All selected folders must be in the same parent directory.\nRun the script again for folders in other locations."
        exit 1
    fi
    NAMES+=("$(basename -- "$f")")
done

# 3. Choose archive name and location
ARCHIVE=$(kdialog --title "Save archive as" --getsavefilename "$HOME/Archive.rar" "*.rar") || exit 0
[[ "$ARCHIVE" == *.rar ]] || ARCHIVE="$ARCHIVE.rar"

if [ -e "$ARCHIVE" ]; then
    kdialog --warningyesno "$ARCHIVE already exists.\nOverwrite it?" || exit 0
    rm -f -- "$ARCHIVE"
fi

# 4. Run rar in Konsole. Arguments are passed as positional parameters,
#    so paths need no manual quoting. --hold keeps the window open afterward.
konsole --hold -e bash -c '
    cd -- "$1" || { echo "Cannot enter $1"; exit 1; }
    archive=$2
    shift 2
    rar a -m0 -rr20 -htb -hp "$archive" "$@"
    rc=$?
    echo
    if [ $rc -eq 0 ]; then
        echo "Archive created: $archive"
    else
        echo "rar failed (exit $rc)"
    fi
' _ "$PARENT" "$ARCHIVE" "${NAMES[@]}"

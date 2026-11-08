#!/usr/bin/env bash
# Creates one store-only RAR per file in a selected folder, using a 20% recovery
# record, BLAKE2 checksums, and encrypted headers. The password is asked once in
# Konsole and used for every archive. Subfolders are skipped and existing archives are not overwritten.

for cmd in rar kdialog konsole; do
    command -v "$cmd" >/dev/null || { echo "$cmd not found in PATH"; exit 1; }
done

DIR=$(kdialog --title "Select folder containing the files" --getexistingdirectory "$HOME") || exit 0

konsole --hold -e bash -c '
    cd -- "$1" || { echo "Cannot enter $1"; exit 1; }

    read -rsp "Archive password: " PW; echo
    read -rsp "Confirm password: " PW2; echo
    [ -n "$PW" ] || { echo "Password cannot be empty."; exit 1; }
    [ "$PW" = "$PW2" ] || { echo "Passwords do not match."; exit 1; }
    unset PW2

    ok=0; fail=0; skip=0
    for f in *; do
        [ -f "$f" ] || continue
        out="$f.rar"
        if [ -e "$out" ]; then
            echo "SKIP (already exists): $out"
            skip=$((skip + 1))
            continue
        fi
        if rar a -m0 -rr20 -htb -hp"$PW" "$out" "$f" >/dev/null; then
            echo "OK: $out"
            ok=$((ok + 1))
        else
            echo "FAILED: $f"
            fail=$((fail + 1))
        fi
    done
    unset PW

    echo
    echo "Done. Created: $ok  Failed: $fail  Skipped: $skip"
' _ "$DIR"

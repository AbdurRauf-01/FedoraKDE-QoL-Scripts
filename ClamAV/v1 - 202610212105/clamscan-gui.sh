#!/usr/bin/env bash
# ClamAV GUI scanner for KDE (needs: kdialog, qdbus, clamav, clamav-update)
# Flow: sudo password dialog -> signature update -> file list (exclusions applied here)
#       -> live progress dialog with total and % -> result dialog

TITLE="ClamAV Scan"
LOG="$HOME/clamscan.log"
OUT="$(mktemp /tmp/clamscan-out.XXXXXX)"
ERR="$(mktemp /tmp/clamscan-err.XXXXXX)"
FRESH="$(mktemp /tmp/clamscan-fresh.XXXXXX)"
LIST="$(mktemp /tmp/clamscan-list.XXXXXX)"

# --- dependency checks ---
for c in kdialog clamscan freshclam sudo stdbuf find; do
  command -v "$c" >/dev/null || { echo "Missing: $c"; exit 1; }
done
QDBUS=""
for q in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
  command -v "$q" >/dev/null && { QDBUS="$q"; break; }
done
[ -z "$QDBUS" ] && { kdialog --error "qdbus not found (try: sudo dnf install qt6-qttools)"; exit 1; }

# --- sudo password dialog ---
# The password is piped to every sudo call (no tty/timestamp dependency, so it also
# works when launched from a .desktop file). It lives only in this script's memory.
PW="$(kdialog --title "$TITLE" --password "Enter your sudo password to start the scan:")" || exit 0
rsudo() { printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
if ! rsudo -v 2>/dev/null; then
  kdialog --title "$TITLE" --error "Wrong password."
  exit 1
fi

# --- progress dialog (busy animation until the file total is known) ---
REF="$(kdialog --title "$TITLE" --progressbar "Updating signatures..." 0)"
read -r SVC OBJ <<< "$REF"
dlg() { "$QDBUS" "$SVC" "$OBJ" "$@" >/dev/null 2>&1; }
cancelled() {
  local r
  r="$("$QDBUS" "$SVC" "$OBJ" org.kde.kdialog.ProgressDialog.wasCancelled 2>/dev/null)" || return 0
  [ "$r" = "true" ]
}

cleanup() {
  dlg close
  rm -f "$OUT" "$ERR" "$FRESH" "$LIST"
  unset PW
}
trap cleanup EXIT

# --- update signatures (continues even if it fails, e.g. lock held by the freshclam service) ---
rsudo freshclam >"$FRESH" 2>&1
FRESH_RC=$?

# --- build the file list (exclusions applied here) ---
dlg org.kde.kdialog.ProgressDialog.setLabelText "Building file list..."
rsudo find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp \
  -o -path /mnt/F442690F4268D83E \) -prune -o -type f -print >"$LIST" 2>/dev/null
TOTAL="$(wc -l <"$LIST")"
if [ "${TOTAL:-0}" -eq 0 ]; then
  dlg close
  kdialog --title "$TITLE" --error "File list is empty, nothing to scan."
  exit 1
fi
dlg org.kde.kdialog.ProgressDialog.maximum "$TOTAL"

# --- scan ---
rsudo stdbuf -oL clamscan --bytecode-timeout=60000 \
  --log="$LOG" --file-list="$LIST" >"$OUT" 2>"$ERR" &
SCAN_PID=$!

USER_CANCELLED=0
while kill -0 "$SCAN_PID" 2>/dev/null; do
  if cancelled; then
    USER_CANCELLED=1
    rsudo pkill -TERM -x clamscan
    break
  fi

  COUNT="$(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT")"
  FOUND_N="$(grep -c ' FOUND$' "$OUT")"
  CURRENT="$(tail -n 1 "$OUT" | cut -c1-90)"
  PCT=$(( COUNT * 100 / TOTAL ))

  LABEL="Scanning...   $COUNT / $TOTAL files ($PCT%)   Detections: $FOUND_N"
  [ "$FRESH_RC" -ne 0 ] && LABEL+=$'\n(signature update failed or was skipped)'
  if [ "$FOUND_N" -gt 0 ]; then
    LABEL+=$'\n\nDETECTED:\n'"$(grep ' FOUND$' "$OUT" | tail -n 5 | cut -c1-110)"
  fi
  LABEL+=$'\n\n'"$CURRENT"

  dlg org.kde.kdialog.ProgressDialog.setLabelText "$LABEL"
  dlg org.kde.kdialog.ProgressDialog.value "$COUNT"
  sleep 1
done

wait "$SCAN_PID" 2>/dev/null
RC=$?
dlg close

# log is root-owned because of sudo; hand it back
rsudo chown "$USER": "$LOG" 2>/dev/null

# --- result dialog ---
COUNT="$(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT")"
FOUND_LIST="$(grep ' FOUND$' "$OUT")"
SUMMARY="$(sed -n '/SCAN SUMMARY/,$p' "$OUT")"
DETAILS="$(head -n 15 "$ERR")"$'\n'"$(tail -n 8 "$OUT")"

if [ "$USER_CANCELLED" -eq 1 ]; then
  kdialog --title "$TITLE" --msgbox "Scan cancelled.\nFiles scanned before cancel: $COUNT of $TOTAL"
elif [ -n "$FOUND_LIST" ]; then
  kdialog --title "$TITLE" --detailedsorry \
    "THREATS FOUND: $(printf '%s\n' "$FOUND_LIST" | wc -l)\nFiles scanned: $COUNT of $TOTAL\n\nLog: $LOG" \
    "$FOUND_LIST"$'\n\n'"$SUMMARY"
elif [ "$COUNT" -eq 0 ]; then
  kdialog --title "$TITLE" --detailederror \
    "No files were scanned (exit code $RC). This is NOT a clean result." "$DETAILS"
elif [ "$RC" -ne 0 ]; then
  kdialog --title "$TITLE" --detailederror \
    "Scan finished with errors (exit code $RC).\nFiles scanned: $COUNT of $TOTAL" \
    "$DETAILS"$'\n\n'"$SUMMARY"
else
  kdialog --title "$TITLE" --msgbox "Scan complete. No threats found.\nFiles scanned: $COUNT of $TOTAL\n\nLog: $LOG"
fi

#!/usr/bin/env bash
# ClamAV GUI scanner for KDE (needs: kdialog, qdbus, clamav, clamav-update)
# Opens a console window (output + live progress) alongside the GUI dialogs.
# Flow: sudo password dialog -> signature update -> file list (exclusions applied here)
#       -> live progress (dialog + console) -> result (dialog + console)
# Run with --no-console to skip the console window.

# --- console: re-launch inside a terminal window unless already in one ---
if [ ! -t 1 ] && [ -z "$CLAM_GUI_IN_TERM" ] && [ "$1" != "--no-console" ]; then
  export CLAM_GUI_IN_TERM=1
  SELF="$(readlink -f "$0")"
  if command -v konsole >/dev/null; then
    exec konsole --hold -e bash "$SELF"
  elif command -v xterm >/dev/null; then
    exec xterm -hold -e bash "$SELF"
  fi
fi

TITLE="ClamAV Scan"
LOG="$HOME/clamscan_$(date +%Y%m%d%H%M%S).log"
OUT="$(mktemp /tmp/clamscan-out.XXXXXX)"
ERR="$(mktemp /tmp/clamscan-err.XXXXXX)"
FRESH="$(mktemp /tmp/clamscan-fresh.XXXXXX)"
LIST="$(mktemp /tmp/clamscan-list.XXXXXX)"
SCAN_PID=""

if [ -t 1 ]; then
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; RST=""
fi
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# --- dependency checks ---
for c in kdialog clamscan freshclam sudo stdbuf find; do
  command -v "$c" >/dev/null || { say "Missing: $c"; exit 1; }
done
QDBUS=""
for q in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
  command -v "$q" >/dev/null && { QDBUS="$q"; break; }
done
[ -z "$QDBUS" ] && { kdialog --error "qdbus not found (try: sudo dnf install qt6-qttools)"; exit 1; }

# --- sudo password dialog ---
# The password is piped to every sudo call (no tty/timestamp dependency, so it also
# works when launched from a .desktop file). It lives only in this script's memory.
say "Waiting for sudo password (dialog)..."
PW="$(kdialog --title "$TITLE" --password "Enter your sudo password to start the scan:")" || exit 0
rsudo() { printf '%s\n' "$PW" | sudo -S -p '' "$@"; }
if ! rsudo -v 2>/dev/null; then
  say "Wrong password."
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
  trap - EXIT INT TERM HUP
  # Ctrl+C or a closed console window: stop a scan that is still running
  if [ -n "$SCAN_PID" ] && kill -0 "$SCAN_PID" 2>/dev/null; then
    rsudo pkill -TERM -x clamscan
    wait "$SCAN_PID" 2>/dev/null
  fi
  dlg close
  rm -f "$OUT" "$ERR" "$FRESH" "$LIST"
  unset PW
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- update signatures (continues even if it fails, e.g. lock held by the freshclam service) ---
say "Updating signatures (freshclam)..."
T_START=$SECONDS
rsudo freshclam 2>&1 | tee "$FRESH"
FRESH_RC=${PIPESTATUS[0]}
T_UPDATED=$SECONDS
if [ "$FRESH_RC" -eq 0 ]; then
  say "Signature update OK."
else
  say "${YEL}Signature update failed or was skipped (exit $FRESH_RC); using the existing database.${RST}"
fi

# --- build the file list (exclusions applied here) ---
say "Building file list..."
dlg org.kde.kdialog.ProgressDialog.setLabelText "Building file list..."
rsudo find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp \
  -o -path /mnt/F442690F4268D83E \) -prune -o -type f -print >"$LIST" 2>/dev/null
TOTAL="$(wc -l <"$LIST")"
if [ "${TOTAL:-0}" -eq 0 ]; then
  dlg close
  say "File list is empty, nothing to scan."
  kdialog --title "$TITLE" --error "File list is empty, nothing to scan."
  exit 1
fi
dlg org.kde.kdialog.ProgressDialog.maximum "$TOTAL"
T_LISTED=$SECONDS
say "File list: $TOTAL files."

# --- scan ---
say "Scanning with clamscan (Cancel button or Ctrl+C stops it)..."
rsudo stdbuf -oL clamscan --bytecode-timeout=60000 \
  --file-list="$LIST" >"$OUT" 2>"$ERR" &
SCAN_PID=$!

USER_CANCELLED=0
SHOWN=0
while kill -0 "$SCAN_PID" 2>/dev/null; do
  if cancelled; then
    USER_CANCELLED=1
    rsudo pkill -TERM -x clamscan
    break
  fi

  # cheap counters: one output line per file, so wc -l is enough while scanning
  COUNT="$(wc -l <"$OUT")"
  FOUND_N="$(grep -c ' FOUND$' "$OUT")"
  CURRENT="$(tail -n 1 "$OUT" | cut -c1-90)"
  PCT=$(( COUNT * 100 / TOTAL )); [ "$PCT" -gt 100 ] && PCT=100

  LABEL="Scanning...   $COUNT / $TOTAL files ($PCT%)   Detections: $FOUND_N"
  [ "$FRESH_RC" -ne 0 ] && LABEL+=$'\n(signature update failed or was skipped)'
  if [ "$FOUND_N" -gt 0 ]; then
    LABEL+=$'\n\nDETECTED:\n'"$(grep ' FOUND$' "$OUT" | tail -n 5 | cut -c1-110)"
  fi
  LABEL+=$'\n\n'"$CURRENT"

  dlg org.kde.kdialog.ProgressDialog.setLabelText "$LABEL"
  dlg org.kde.kdialog.ProgressDialog.value "$COUNT"

  # console: new detections on their own line, then the live progress line
  if [ -t 1 ]; then
    if [ "$FOUND_N" -gt "$SHOWN" ]; then
      printf '\r\033[K'
      grep ' FOUND$' "$OUT" | tail -n +"$((SHOWN + 1))" | while IFS= read -r l; do
        printf '%sDETECTED: %s%s\n' "$RED" "$l" "$RST"
      done
      SHOWN=$FOUND_N
    fi
    printf '\r\033[K[%s] Scanned %s / %s files (%s%%)  Detections: %s' \
      "$(date +%H:%M:%S)" "$COUNT" "$TOTAL" "$PCT" "$FOUND_N"
  fi
  sleep 2
done
[ -t 1 ] && printf '\r\033[K'

wait "$SCAN_PID" 2>/dev/null
RC=$?
T_DONE=$SECONDS
dlg close

# --- write log: irregular lines only (no OK / Empty file / Symbolic link) ---
# Written by this script as your user, so no chown is needed.
{
  echo "ClamAV scan log - $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Scanner: clamscan | Files in list: $TOTAL | Files scanned: $(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT") | Exit code: $RC"
  echo "Database: $(clamscan --version 2>/dev/null | head -n 1)"
  echo "Signature update: $([ "$FRESH_RC" -eq 0 ] && echo OK || echo "FAILED or skipped (exit $FRESH_RC)")"
  [ "$FRESH_RC" -ne 0 ] && { echo "freshclam output (last lines):"; tail -n 5 "$FRESH"; }
  echo "Timing: signature update $((T_UPDATED-T_START))s | file list $((T_LISTED-T_UPDATED))s | scan $((T_DONE-T_LISTED))s"
  [ "$USER_CANCELLED" -eq 1 ] && echo "NOTE: scan was cancelled before it finished"
  echo
  grep -v -E ': (OK|Empty file|Symbolic link)$' "$OUT"
  if [ -s "$ERR" ]; then echo; echo "--- stderr ---"; cat "$ERR"; fi
} > "$LOG"

# --- result ---
COUNT="$(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT")"
FOUND_LIST="$(grep ' FOUND$' "$OUT")"
FOUND_N="$(grep -c ' FOUND$' "$OUT")"
SUMMARY="$(sed -n '/SCAN SUMMARY/,$p' "$OUT")"
DETAILS="$(head -n 15 "$ERR")"$'\n'"$(tail -n 8 "$OUT")"

if [ "$USER_CANCELLED" -eq 1 ]; then
  STATUS="Scan cancelled"; COL="$YEL"
elif [ -n "$FOUND_LIST" ]; then
  STATUS="THREATS FOUND: $FOUND_N"; COL="$RED"
elif [ "$COUNT" -eq 0 ]; then
  STATUS="No files were scanned (exit code $RC) - NOT a clean result"; COL="$RED"
elif [ "$RC" -ne 0 ]; then
  STATUS="Scan finished with errors (exit code $RC)"; COL="$YEL"
else
  STATUS="Scan complete - no threats found"; COL="$GRN"
fi

# console result
echo
printf '%s%s%s\n' "$COL" "$STATUS" "$RST"
echo "Files scanned : $COUNT of $TOTAL"
echo "Timing        : scan $((T_DONE-T_LISTED))s (signature update $((T_UPDATED-T_START))s, file list $((T_LISTED-T_UPDATED))s)"
echo "Log           : $LOG"
[ -n "$FOUND_LIST" ] && { echo; echo "Detections:"; echo "$FOUND_LIST"; }
if [ "$RC" -ne 0 ] && [ -z "$FOUND_LIST" ] && [ -s "$ERR" ]; then echo; echo "Errors/warnings:"; head -n 15 "$ERR"; fi

# dialog result
if [ "$USER_CANCELLED" -eq 1 ]; then
  kdialog --title "$TITLE" --msgbox "Scan cancelled.\nFiles scanned before cancel: $COUNT of $TOTAL"
elif [ -n "$FOUND_LIST" ]; then
  kdialog --title "$TITLE" --detailedsorry \
    "THREATS FOUND: $FOUND_N\nFiles scanned: $COUNT of $TOTAL\n\nLog: $LOG" \
    "$FOUND_LIST"$'\n\n'"$SUMMARY"
elif [ "$COUNT" -eq 0 ]; then
  kdialog --title "$TITLE" --detailederror \
    "No files were scanned (exit code $RC). This is NOT a clean result." "$DETAILS"
elif [ "$RC" -ne 0 ]; then
  kdialog --title "$TITLE" --detailederror \
    "Scan finished with errors (exit code $RC).\nFiles scanned: $COUNT of $TOTAL" \
    "$DETAILS"$'\n\n'"$SUMMARY"
else
  kdialog --title "$TITLE" --msgbox "Scan complete. No threats found.\nFiles scanned: $COUNT of $TOTAL\nScan time: $((T_DONE-T_LISTED))s\n\nLog: $LOG"
fi

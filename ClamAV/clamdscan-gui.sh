#!/usr/bin/env bash
# ClamAV daemon (clamdscan) GUI scanner for KDE
# Needs: kdialog, qdbus, clamd (sudo dnf install clamd clamav clamav-update)
# Flow: sudo password dialog -> config check -> signature update -> daemon start/reload
#       -> file list (exclusions applied here) -> live progress dialog -> result dialog

TITLE="ClamAV Daemon Scan"
SERVICE="clamd@scan"
CONF="/etc/clamd.d/scan.conf"
LOG="$HOME/clamscan.log"
OUT="$(mktemp /tmp/clamdscan-out.XXXXXX)"
ERR="$(mktemp /tmp/clamdscan-err.XXXXXX)"
FRESH="$(mktemp /tmp/clamdscan-fresh.XXXXXX)"
LIST="$(mktemp /tmp/clamdscan-list.XXXXXX)"
STARTED=0
NEED_RESTART=0

# --- dependency checks ---
for c in kdialog clamdscan freshclam sudo stdbuf systemctl find; do
  command -v "$c" >/dev/null || { echo "Missing: $c"; exit 1; }
done
[ -f "$CONF" ] || { kdialog --error "$CONF not found.\nInstall the daemon: sudo dnf install clamd"; exit 1; }
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

# --- daemon config check (exclusions are NOT needed here: they are applied to the file list) ---
MISSING=()
rsudo grep -q '^BytecodeTimeout' "$CONF" || MISSING+=("BytecodeTimeout 60000")
rsudo grep -q '^LocalSocket' "$CONF" || MISSING+=("LocalSocket /run/clamd.scan/clamd.sock")
HAS_EXAMPLE=0
rsudo grep -q '^Example' "$CONF" && HAS_EXAMPLE=1
DUP_SOCKET="$(rsudo grep -c '^LocalSocket' "$CONF")"

if [ "${#MISSING[@]}" -gt 0 ] || [ "$HAS_EXAMPLE" -eq 1 ] || [ "${DUP_SOCKET:-0}" -gt 1 ]; then
  MSG="$CONF needs changes for this scan:\n"
  [ "$HAS_EXAMPLE" -eq 1 ] && MSG+="\n- comment out the 'Example' line (clamd refuses to start with it)"
  [ "${DUP_SOCKET:-0}" -gt 1 ] && MSG+="\n- remove duplicate LocalSocket lines"
  for m in "${MISSING[@]}"; do MSG+="\n- add: $m"; done
  MSG+="\n\nApply them now?"
  if kdialog --title "$TITLE" --yesno "$MSG"; then
    [ "$HAS_EXAMPLE" -eq 1 ] && rsudo sed -i 's/^Example/#Example/' "$CONF"
    if [ "${DUP_SOCKET:-0}" -gt 1 ]; then
      # keep the first LocalSocket line, delete the rest
      rsudo awk '/^LocalSocket/ { if (seen++) next } { print }' "$CONF" > "$ERR" \
        && rsudo cp "$ERR" "$CONF"
    fi
    if [ "${#MISSING[@]}" -gt 0 ]; then
      printf '%s\n' "${MISSING[@]}" > "$FRESH"
      rsudo bash -c 'cat "$1" >> "$2"' _ "$FRESH" "$CONF"
    fi
    NEED_RESTART=1
  fi
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
  [ "$STARTED" -eq 1 ] && rsudo systemctl stop "$SERVICE" 2>/dev/null
  dlg close
  rm -f "$OUT" "$ERR" "$FRESH" "$LIST"
  unset PW
}
trap cleanup EXIT

# --- update signatures (continues even if it fails, e.g. lock held by the freshclam service) ---
rsudo freshclam >"$FRESH" 2>&1
FRESH_RC=$?

# --- daemon: start, restart (config changed) or reload (new signatures) ---
dlg org.kde.kdialog.ProgressDialog.setLabelText "Starting clamd (loading signatures, this can take a minute)..."
if systemctl is-active --quiet "$SERVICE"; then
  if [ "$NEED_RESTART" -eq 1 ]; then
    rsudo systemctl restart "$SERVICE"
  else
    rsudo clamdscan -c "$CONF" --reload >/dev/null 2>&1
  fi
else
  rsudo systemctl start "$SERVICE" 2>"$ERR"
  STARTED=1
fi

PING_OUT="$(rsudo clamdscan -c "$CONF" --ping 60:2 2>&1)"
if [ $? -ne 0 ]; then
  dlg close
  STATE="$(systemctl is-active "$SERVICE")"
  kdialog --title "$TITLE" --detailederror \
    "clamdscan could not reach clamd (service state: $STATE).\nThe details show the actual error." \
    "ping output:"$'\n'"$PING_OUT"$'\n\n'"journal:"$'\n'"$(rsudo journalctl -u "$SERVICE" -n 15 --no-pager 2>&1)"
  exit 1
fi

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
rsudo stdbuf -oL clamdscan -c "$CONF" --fdpass --file-list="$LIST" \
  --log="$LOG" >"$OUT" 2>"$ERR" &
SCAN_PID=$!

USER_CANCELLED=0
while kill -0 "$SCAN_PID" 2>/dev/null; do
  if cancelled; then
    USER_CANCELLED=1
    rsudo pkill -TERM -x clamdscan
    break
  fi

  COUNT="$(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT")"
  FOUND_N="$(grep -c ' FOUND$' "$OUT")"
  CURRENT="$(tail -n 1 "$OUT" | cut -c1-90)"
  PCT=$(( COUNT * 100 / TOTAL ))

  LABEL="Scanning (daemon)...   $COUNT / $TOTAL files ($PCT%)   Detections: $FOUND_N"
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
DETAILS="$(head -n 15 "$ERR")"$'\n'"$(grep -v -E ': (OK|Empty file)$' "$OUT" | tail -n 10)"

if [ "$USER_CANCELLED" -eq 1 ]; then
  kdialog --title "$TITLE" --msgbox "Scan cancelled.\nFiles scanned before cancel: $COUNT"
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

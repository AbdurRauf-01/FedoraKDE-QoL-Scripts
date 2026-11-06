#!/usr/bin/env bash
# ClamAV daemon (clamdscan) GUI scanner for KDE
# Needs: kdialog, qdbus, clamd (sudo dnf install clamd clamav clamav-update)
# Opens a console window (output + live progress) alongside the GUI dialogs.
# clamd is started on demand and stopped again after the scan (it never needs to run at boot).
# Flow: sudo password dialog -> autostart + config check -> signature update -> start/reload clamd
#       -> file list (exclusions applied here) -> live progress (dialog + console) -> result
# Scans run in parallel (about 80% of the CPU cores, capped by clamd MaxThreads).
# Options: --no-console   skip the console window
#          --jobs=N       force N parallel workers

# --- console: re-launch inside a terminal window unless already in one ---
if [ ! -t 1 ] && [ -z "$CLAM_GUI_IN_TERM" ] && [ "$1" != "--no-console" ]; then
  export CLAM_GUI_IN_TERM=1
  SELF="$(readlink -f "$0")"
  if command -v konsole >/dev/null; then
    exec konsole --hold -e bash "$SELF" "$@"
  elif command -v xterm >/dev/null; then
    exec xterm -hold -e bash "$SELF" "$@"
  fi
fi

JOBS_OVERRIDE=""
for a in "$@"; do
  case "$a" in --jobs=*) JOBS_OVERRIDE="${a#--jobs=}" ;; esac
done
[[ "$JOBS_OVERRIDE" =~ ^[0-9]+$ ]] || JOBS_OVERRIDE=""

TITLE="ClamAV Daemon Scan"
SERVICE="clamd@scan"
CONF="/etc/clamd.d/scan.conf"
LOG="$HOME/clamdscan_$(date +%Y%m%d%H%M%S).log"
OUT="$(mktemp /tmp/clamdscan-out.XXXXXX)"
ERR="$(mktemp /tmp/clamdscan-err.XXXXXX)"
FRESH="$(mktemp /tmp/clamdscan-fresh.XXXXXX)"
LIST="$(mktemp /tmp/clamdscan-list.XXXXXX)"
SCAN_PID=""
CHUNK_DIR=""
PAT=""
STARTED=0      # 1 = this script owns the daemon's lifetime and stops it when done
NEED_RESTART=0

if [ -t 1 ]; then
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; RST=""
fi
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# --- dependency checks ---
for c in kdialog clamdscan freshclam sudo stdbuf systemctl find; do
  command -v "$c" >/dev/null || { say "Missing: $c"; exit 1; }
done
[ -f "$CONF" ] || { say "$CONF not found."; kdialog --error "$CONF not found.\nInstall the daemon: sudo dnf install clamd"; exit 1; }
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

# --- autostart check: clamd should only run while this script uses it ---
if [ "$(systemctl is-enabled "$SERVICE" 2>/dev/null)" = "enabled" ]; then
  if kdialog --title "$TITLE" --yesno "$SERVICE is set to start at boot.\n\nDisable autostart? This script starts clamd on demand and stops it after the scan (also after this one)."; then
    if rsudo systemctl disable "$SERVICE" >/dev/null 2>&1; then
      say "Disabled autostart for $SERVICE."
      STARTED=1   # it may already be running from boot; stop it after this scan too
    else
      say "${YEL}Could not disable autostart for $SERVICE.${RST}"
    fi
  fi
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
  say "$CONF needs changes (asking in a dialog)..."
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
    say "Applied config changes."
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

# stop clamd if this script owns it (started it, or you chose to disable autostart)
stop_daemon() {
  if [ "$STARTED" -eq 1 ]; then
    say "Stopping clamd..."
    rsudo systemctl stop "$SERVICE" 2>/dev/null
    STARTED=0
  fi
}

# stop all scan workers (xargs, worker shells, scanners): they all carry the chunk dir name
stop_workers() {
  [ -n "$CHUNK_DIR" ] || return 0
  : >"$CHUNK_DIR/cancel"
  rsudo pkill -TERM -f "$PAT" 2>/dev/null
}

cleanup() {
  trap - EXIT INT TERM HUP
  # Ctrl+C or a closed console window: stop a scan that is still running
  if [ -n "$SCAN_PID" ] && kill -0 "$SCAN_PID" 2>/dev/null; then
    stop_workers
    { wait "$SCAN_PID"; } 2>/dev/null
  fi
  stop_daemon
  dlg close
  rm -f "$OUT" "$ERR" "$FRESH" "$LIST"
  [ -n "$CHUNK_DIR" ] && rm -rf "$CHUNK_DIR"
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

# --- daemon: start (on demand), restart (config changed) or reload (new signatures) ---
dlg org.kde.kdialog.ProgressDialog.setLabelText "Starting clamd (loading signatures, this can take a minute)..."
if systemctl is-active --quiet "$SERVICE"; then
  if [ "$NEED_RESTART" -eq 1 ]; then
    say "Restarting $SERVICE (config changed)..."
    rsudo systemctl restart "$SERVICE"
  else
    say "$SERVICE already running; reloading signatures..."
    rsudo clamdscan -c "$CONF" --reload >/dev/null 2>&1
  fi
else
  say "Starting $SERVICE (loading signatures, can take up to a minute or two)..."
  rsudo systemctl start "$SERVICE" 2>"$ERR"
  STARTED=1
fi

say "Waiting for clamd to answer..."
PING_OUT="$(rsudo clamdscan -c "$CONF" --ping 60:2 2>&1)"
if [ $? -ne 0 ]; then
  dlg close
  STATE="$(systemctl is-active "$SERVICE")"
  JOURNAL="$(rsudo journalctl -u "$SERVICE" -n 15 --no-pager 2>&1)"
  say "${RED}clamd did not come up (service state: $STATE).${RST}"
  printf '%s\n\n%s\n' "$PING_OUT" "$JOURNAL"
  stop_daemon
  kdialog --title "$TITLE" --detailederror \
    "clamdscan could not reach clamd (service state: $STATE).\nThe details show the actual error." \
    "ping output:"$'\n'"$PING_OUT"$'\n\n'"journal:"$'\n'"$JOURNAL"
  exit 1
fi
say "clamd is up."

T_DAEMON=$SECONDS

# --- build the file list (exclusions applied here) ---
say "Building file list..."
dlg org.kde.kdialog.ProgressDialog.setLabelText "Building file list..."
rsudo find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp \
  -o -path /mnt/F442690F4268D83E \) -prune -o -type f -print >"$LIST" 2>/dev/null
TOTAL="$(wc -l <"$LIST")"
if [ "${TOTAL:-0}" -eq 0 ]; then
  dlg close
  say "File list is empty, nothing to scan."
  stop_daemon
  kdialog --title "$TITLE" --error "File list is empty, nothing to scan."
  exit 1
fi
dlg org.kde.kdialog.ProgressDialog.maximum "$TOTAL"
T_LISTED=$SECONDS
say "File list: $TOTAL files."

# --- scan: parallel clamdscan workers (each worker = one clamd scan thread) ---
NPROC="$(nproc 2>/dev/null || echo 1)"
JOBS="${JOBS_OVERRIDE:-$(( (NPROC * 80 + 50) / 100 ))}"      # about 80% of the cores
MAXT="$(rsudo grep -E '^MaxThreads' "$CONF" 2>/dev/null | awk 'NR==1{print $2}')"
[[ "$MAXT" =~ ^[0-9]+$ ]] || MAXT=10                         # clamd default
[ "$JOBS" -gt "$MAXT" ] && JOBS="$MAXT"                      # clamd serves at most MaxThreads at once
[ "$JOBS" -lt 1 ] && JOBS=1

# split the list into small chunks; workers pick the next free chunk, so load stays balanced
CHUNK_DIR="$(mktemp -d /tmp/clamdscan-chunks.XXXXXX)"
# Work files that the root workers append to must NOT sit directly in /tmp: with fs.protected_regular
# (the Fedora default) root may not open a user-owned file in a sticky dir like /tmp. Inside the
# private chunk dir it is fine.
rm -f "$OUT" "$ERR"
OUT="$CHUNK_DIR/out"; ERR="$CHUNK_DIR/err"
: >"$OUT"; : >"$ERR"
TAG="${CHUNK_DIR##*/}"
PAT="${TAG%?}[${TAG: -1}]"          # matches the chunk dir name but not pkill's own command line
split -l 1000 -d -a 5 "$LIST" "$CHUNK_DIR/c."
printf '%s\n' "$CHUNK_DIR"/c.* >"$CHUNK_DIR/queue.txt"
RCF="$CHUNK_DIR/rc"; : >"$RCF"
# worker code is passed as an argument (not a file) so root never runs a user-writable script
WORKER='conf=$1; out=$2; err=$3; rcf=$4; flag=$5; chunk=$6
[ -e "$flag" ] && exit 0
: 2>/dev/null >>"$out" || { echo "worker cannot write to $out" >&2; : >"$flag"; exit 0; }
stdbuf -oL clamdscan -c "$conf" --fdpass --no-summary --file-list="$chunk" >>"$out" 2>>"$err"
echo $? >>"$rcf"'

say "Scanning with clamdscan: $JOBS parallel workers on $NPROC cores (Cancel button or Ctrl+C stops it)..."
rsudo xargs -r -a "$CHUNK_DIR/queue.txt" -n 1 -P "$JOBS" \
  bash -c "$WORKER" worker "$CONF" "$OUT" "$ERR" "$RCF" "$CHUNK_DIR/cancel" &
SCAN_PID=$!

USER_CANCELLED=0
SHOWN=0
while kill -0 "$SCAN_PID" 2>/dev/null; do
  if cancelled; then
    USER_CANCELLED=1
    stop_workers
    break
  fi

  # cheap counters: one output line per file, so wc -l is enough while scanning
  COUNT="$(wc -l <"$OUT")"
  FOUND_N="$(grep -c ' FOUND$' "$OUT")"
  CURRENT="$(tail -n 1 "$OUT" | cut -c1-90)"
  PCT=$(( COUNT * 100 / TOTAL )); [ "$PCT" -gt 100 ] && PCT=100

  LABEL="Scanning (daemon, $JOBS workers)...   $COUNT / $TOTAL files ($PCT%)   Detections: $FOUND_N"
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

{ wait "$SCAN_PID"; } 2>/dev/null
WAIT_RC=$?
T_DONE=$SECONDS
# worst exit code of all chunks: 0 clean, 1 detections, 2 error
RC="$(sort -n "$RCF" 2>/dev/null | tail -n 1)"
RC="${RC:-$WAIT_RC}"
dlg close

# stop clamd now (also when cancelled), not only after the result dialog is closed
[ "$USER_CANCELLED" -eq 1 ] && STARTED=1
stop_daemon

# --- write log: irregular lines only (no OK / Empty file / Symbolic link) ---
# Written by this script as your user, so no chown is needed.
{
  echo "ClamAV daemon scan log - $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Scanner: clamdscan ($JOBS workers) | Files in list: $TOTAL | Files scanned: $(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT") | Exit code: $RC"
  echo "Database: $({ clamscan --version || clamdscan --version; } 2>/dev/null | head -n 1)"
  echo "Signature update: $([ "$FRESH_RC" -eq 0 ] && echo OK || echo "FAILED or skipped (exit $FRESH_RC)")"
  [ "$FRESH_RC" -ne 0 ] && { echo "freshclam output (last lines):"; tail -n 5 "$FRESH"; }
  echo "Timing: signature update $((T_UPDATED-T_START))s | daemon start/reload $((T_DAEMON-T_UPDATED))s | file list $((T_LISTED-T_DAEMON))s | scan $((T_DONE-T_LISTED))s"
  [ "$USER_CANCELLED" -eq 1 ] && echo "NOTE: scan was cancelled before it finished"
  echo
  grep -v -E ': (OK|Empty file|Symbolic link)$' "$OUT"
  if [ -s "$ERR" ]; then echo; echo "--- stderr ---"; cat "$ERR"; fi
} > "$LOG"

# --- result ---
COUNT="$(grep -c -E ': (OK|Empty file|.+ FOUND)$' "$OUT")"
FOUND_LIST="$(grep ' FOUND$' "$OUT")"
FOUND_N="$(grep -c ' FOUND$' "$OUT")"
SUMMARY="----------- SCAN SUMMARY -----------"$'\n'"Infected files: $FOUND_N"$'\n'"Scanned files: $COUNT of $TOTAL"$'\n'"Workers: $JOBS"$'\n'"Scan time: $((T_DONE-T_LISTED))s"
DETAILS="$(head -n 15 "$ERR")"$'\n'"$(grep -v -E ': (OK|Empty file)$' "$OUT" | tail -n 10)"

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
echo "Workers       : $JOBS parallel on $NPROC cores"
echo "Timing        : scan $((T_DONE-T_LISTED))s (signature update $((T_UPDATED-T_START))s, daemon start $((T_DAEMON-T_UPDATED))s, file list $((T_LISTED-T_DAEMON))s)"
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

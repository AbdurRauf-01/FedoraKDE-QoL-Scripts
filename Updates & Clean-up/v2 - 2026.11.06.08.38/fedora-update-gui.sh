#!/usr/bin/env bash
# fedora-update-gui.sh
# GUI version of the Fedora update script. A selection dialog lists the update tasks,
# all ticked by default. The ticked tasks run in a console window while a progress
# window shows the current step.
# Updates within the current Fedora release only. Release upgrades (44 -> 45) are never run.
set -u

# ---------------------------------------------------------------------------
# Open a console window if started without a terminal (double-click)
# ---------------------------------------------------------------------------
if [ ! -t 1 ] && [ -z "${FEDORA_GUI_IN_TERM:-}" ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  export FEDORA_GUI_IN_TERM=1
  _self="$(readlink -f "${BASH_SOURCE[0]}")"
  _wrap='bash "$@"; rc=$?; echo; read -r -p "Finished (exit code $rc). Press Enter to close this window... " _'
  for _t in konsole ptyxis gnome-terminal xfce4-terminal mate-terminal alacritty kitty foot xterm; do
    command -v "$_t" >/dev/null 2>&1 || continue
    case "$_t" in
      gnome-terminal|ptyxis)        exec "$_t" -- bash -c "$_wrap" _ "$_self" ;;
      xfce4-terminal|mate-terminal) exec "$_t" -x bash -c "$_wrap" _ "$_self" ;;
      kitty|foot)                   exec "$_t" bash -c "$_wrap" _ "$_self" ;;
      *)                            exec "$_t" -e bash -c "$_wrap" _ "$_self" ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
DIALOG_TOOL="auto"      # auto | zenity | kdialog
DIALOG_WIDTH=700
DIALOG_HEIGHT=400
FINISH_LINGER=3         # seconds the final message stays in the progress window

# Format: key | command that must exist | label | ticked on launch (TRUE/FALSE)
ITEMS=(
  "dnf|dnf|System packages (dnf upgrade --refresh)|TRUE"
  "flatpak|flatpak|Flatpak apps (flatpak update)|TRUE"
  "firmware|fwupdmgr|Firmware (fwupdmgr update)|TRUE"
)

# ---------------------------------------------------------------------------
# GUI tool
# ---------------------------------------------------------------------------
GUI_TOOL=""
case "$DIALOG_TOOL" in
  zenity)  command -v zenity  >/dev/null 2>&1 && GUI_TOOL=zenity ;;
  kdialog) command -v kdialog >/dev/null 2>&1 && GUI_TOOL=kdialog ;;
  *)       if   command -v zenity  >/dev/null 2>&1; then GUI_TOOL=zenity
           elif command -v kdialog >/dev/null 2>&1; then GUI_TOOL=kdialog; fi ;;
esac
if [ -z "$GUI_TOOL" ]; then
  echo "Install zenity or kdialog for the dialogs (sudo dnf install zenity)." >&2
  exit 1
fi

join() { local IFS=', '; printf '%s' "$*"; }

label_of() {   # label_of <key>
  local line key cmd label state
  for line in "${ITEMS[@]}"; do
    IFS='|' read -r key cmd label state <<<"$line"
    [ "$key" = "$1" ] && { printf '%s' "$label"; return; }
  done
}

# ---------------------------------------------------------------------------
# Selection dialog. Fills SELECTED with the keys of the ticked tasks.
# ---------------------------------------------------------------------------
SELECTED=()
select_tasks() {
  local title="$1" line key cmd label state st out geo=() rows=()
  for line in "${ITEMS[@]}"; do
    IFS='|' read -r key cmd label state <<<"$line"
    command -v "$cmd" >/dev/null 2>&1 || continue
    if [ "$GUI_TOOL" = zenity ]; then
      rows+=("$state" "$label" "$key")
    else
      st=off; [ "$state" = TRUE ] && st=on
      rows+=("$key" "$label" "$st")
    fi
  done
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "None of the update tools are installed."; exit 1
  fi

  if [ "$GUI_TOOL" = zenity ]; then
    out="$(zenity --list --checklist --title="$title" \
      --text="Tick the updates to run, then press OK. Package changes are confirmed in the console window." \
      --column="Run" --column="Update" --column="key" \
      --hide-column=3 --print-column=3 --separator=$'\n' \
      --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" "${rows[@]}")" || exit 0
  else
    # --geometry is honoured on X11 only; pass it only if this kdialog knows the option
    if kdialog --help-all 2>&1 | grep -q -- '--geometry'; then
      geo=(--geometry "${DIALOG_WIDTH}x${DIALOG_HEIGHT}")
    fi
    out="$(kdialog ${geo[@]+"${geo[@]}"} --title "$title" --separate-output \
      --checklist "Tick the updates to run, then press OK:" "${rows[@]}")" || exit 0
  fi
  [ -z "$out" ] && { echo "Nothing selected."; exit 0; }
  mapfile -t SELECTED <<<"$out"
}

# ---------------------------------------------------------------------------
# Progress window (single-line text, so it works with both tools)
# ---------------------------------------------------------------------------
PROG_ON=0; ZPID=""; ZFIFO=""; QDBUS=""; KD_SVC=""; KD_PATH=""
trap '' PIPE

progress_start() {
  local title="$1" q
  if [ "$GUI_TOOL" = zenity ]; then
    ZFIFO="$(mktemp -u "${TMPDIR:-/tmp}/fedora-gui.XXXXXX")"
    mkfifo "$ZFIFO" || return 0
    zenity --progress --title="$title" --text="Starting..." --percentage=0 \
      --no-cancel --no-markup --width=680 <"$ZFIFO" >/dev/null 2>&1 &
    ZPID=$!
    exec 3<>"$ZFIFO"
    PROG_ON=1
  else
    for q in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
      command -v "$q" >/dev/null 2>&1 && { QDBUS="$q"; break; }
    done
    [ -n "$QDBUS" ] || { echo "(qdbus not found - progress window disabled)"; return 0; }
    local ref
    ref="$(kdialog --title "$title" --progressbar "Starting..." 100 2>/dev/null)" || return 0
    read -r KD_SVC KD_PATH <<<"$ref"
    [ -n "${KD_SVC:-}" ] && PROG_ON=1
  fi
}

progress_update() {   # progress_update <percent> <single-line text>
  [ "$PROG_ON" = 1 ] || return 0
  local pct=$1 text=$2
  if [ "$GUI_TOOL" = zenity ]; then
    printf '%s\n# %s\n' "$pct" "$text" >&3 2>/dev/null
  else
    "$QDBUS" "$KD_SVC" "$KD_PATH" Set "" value "$pct" >/dev/null 2>&1
    "$QDBUS" "$KD_SVC" "$KD_PATH" setLabelText "$text" >/dev/null 2>&1
  fi
}

progress_stop() {
  [ "$PROG_ON" = 1 ] || return 0
  PROG_ON=0
  if [ "$GUI_TOOL" = zenity ]; then
    exec 3>&-
    kill "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null
    rm -f "$ZFIFO"
  else
    "$QDBUS" "$KD_SVC" "$KD_PATH" close >/dev/null 2>&1
  fi
}
trap 'progress_stop' EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM HUP

# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------
firmware_update() {
  sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
  sudo fwupdmgr update
  local rc=$?
  # fwupdmgr exits with 2 when there is nothing to update
  if (( rc == 2 )); then echo "No firmware updates available."; return 0; fi
  return $rc
}

run_task() {   # run_task <key>
  case "$1" in
    dnf)      sudo dnf upgrade --refresh ;;
    flatpak)  flatpak update ;;
    firmware) firmware_update ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
select_tasks "Fedora update"
progress_start "Fedora update"

DONE=(); FAILED=(); reboot=0
total=${#SELECTED[@]}; i=0
for key in "${SELECTED[@]}"; do
  i=$((i + 1))
  label="$(label_of "$key")"
  progress_update $(( (i - 1) * 100 / total )) "Step $i of $total: $label"
  echo; echo "==> $label"
  if run_task "$key"; then
    echo "[done] $label"; DONE+=("$label")
  else
    echo "[failed] $label"; FAILED+=("$label")
  fi
done

# Reboot check (dnf-plugins-core: needs-restarting -r exits 1 when a reboot is needed)
if [[ " ${SELECTED[*]} " == *" dnf "* ]]; then
  sudo dnf needs-restarting -r >/dev/null 2>&1 || reboot=1
fi

msg="Finished: ${#DONE[@]} of $total step(s) succeeded"
(( ${#FAILED[@]} )) && msg+=" | Failed: $(join "${FAILED[@]}")"
(( reboot )) && msg+=" | Reboot required"
echo; echo "$msg"

progress_update 100 "$msg"
sleep "$FINISH_LINGER"
command -v notify-send >/dev/null 2>&1 && notify-send "Fedora update finished" "$msg"

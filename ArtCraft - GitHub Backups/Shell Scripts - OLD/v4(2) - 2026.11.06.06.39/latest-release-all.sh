#!/usr/bin/env bash
# Downloads selected assets of each chosen repo's latest release into
# ~/Downloads/"<release name>"/
#  - Opens its own console window when started from a launcher / file manager.
#  - A (bigger) selection dialog opens on launch; all repos are ticked by default.
#  - A GUI progress window shows the current repo + file, speed, ETA and
#    the repos that are already finished. Press Cancel in it (or Ctrl+C) to stop.
set -u

# ---------------------------------------------------------------------------
# Open a console window if we were started without a terminal
# ---------------------------------------------------------------------------
if [ ! -t 1 ] && [ -z "${DL_IN_CONSOLE:-}" ]; then
  export DL_IN_CONSOLE=1
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  inner='bash "$1"; echo; read -r -p "Press Enter to close this window... " _'
  if   command -v konsole        >/dev/null; then exec konsole -e bash -c "$inner" _ "$self"
  elif command -v ptyxis         >/dev/null; then exec ptyxis -- bash -c "$inner" _ "$self"
  elif command -v gnome-terminal >/dev/null; then exec gnome-terminal -- bash -c "$inner" _ "$self"
  elif command -v xfce4-terminal >/dev/null; then exec xfce4-terminal -x bash -c "$inner" _ "$self"
  elif command -v mate-terminal  >/dev/null; then exec mate-terminal -x bash -c "$inner" _ "$self"
  elif command -v alacritty      >/dev/null; then exec alacritty -e bash -c "$inner" _ "$self"
  elif command -v kitty          >/dev/null; then exec kitty bash -c "$inner" _ "$self"
  elif command -v foot           >/dev/null; then exec foot bash -c "$inner" _ "$self"
  elif command -v xterm          >/dev/null; then exec xterm -e bash -c "$inner" _ "$self"
  fi
fi

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
REPOS=(
  "https://github.com/storytold/artcraft"
  "https://github.com/storytold/craft-launcher"
  "https://github.com/storytold/artcraft-services"
  "https://github.com/storytold/photocraft"
  "https://github.com/storytold/lightcraft"
  "https://github.com/storytold/filmcraft"
  "https://github.com/storytold/vectorcraft"
  "https://github.com/storytold/pdfcraft"
  "https://github.com/storytold/effectcraft"
  "https://github.com/storytold/designcraft"
  "https://github.com/storytold/figcraft"
  "https://github.com/storytold/soundcraft"
  "https://github.com/storytold/cadcraft"
  "https://github.com/storytold/texturecraft"
  "https://github.com/storytold/materialcraft"
  "https://github.com/storytold/wordcraft"
  "https://github.com/storytold/deckcraft"
  "https://github.com/storytold/gridcraft"
  "https://github.com/storytold/craft-anything"
  "https://github.com/tangency-labs/solidcraft"
  # add more repo URLs here, one per line
)

# Only assets whose file name ENDS with one of these are downloaded
# (case-insensitive). Leave the list empty to download every asset.
# Add more lines to also grab e.g. "-linux-x86_64.flatpak.asc" or "SHA256SUMS.txt".
ASSET_SUFFIXES=(
  "-linux-x86_64.flatpak"
  "-windows-x64.msi"
  "-linux-x86_64.flatpak.asc"
  "-windows-x64.msi.asc"
)

DEFAULT_CHECKED="TRUE"    # TRUE = all ticked on launch, FALSE = none ticked

# Dialog look: auto = zenity if installed (its size is fully controllable),
# otherwise kdialog. Force one with: zenity | kdialog
DIALOG_TOOL="auto"
DIALOG_WIDTH=900
DIALOG_HEIGHT=800

OUT_DIR="$HOME/Downloads"
TOKEN_FILE="$HOME/.config/github-token"
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

AUTH=()
if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
fi

for cmd in curl jq awk stat; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
log() { [ -t 1 ] && printf '\r\033[K'; printf '%s\n' "$*"; }

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    fmt = (i == 1) ? "%.0f %s" : "%.1f %s"; printf fmt, b, u[i] }'
}

fmt_time() {
  local s=${1:-0}; [ "$s" -lt 0 ] && s=0
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

bar() {   # bar <percent> <width>
  local p=$1 w=${2:-20} f e
  f=$((p*w/100)); e=$((w-f))
  printf '[%s%s]' "$(printf '%*s' "$f" '' | tr ' ' '#')" "$(printf '%*s' "$e" '' | tr ' ' '-')"
}

tail_list() {   # tail_list <array name>  -> "a, b, c" (last 6 only)
  local -n _arr=$1
  local n=${#_arr[@]} max=6 start=0 i out=""
  [ "$n" -eq 0 ] && { printf 'none yet'; return; }
  [ "$n" -gt "$max" ] && start=$((n-max))
  for ((i=start; i<n; i++)); do out+="${_arr[i]}, "; done
  out="${out%, }"
  [ "$start" -gt 0 ] && out="... +$start earlier, $out"
  printf '%s' "$out"
}

# Remove characters that are not allowed in folder names
sanitize() {
  printf '%s' "$1" | tr -d '/\\:*?"<>|' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Returns 0 if the asset name matches one of ASSET_SUFFIXES (or the list is empty)
want_asset() {
  [ "${#ASSET_SUFFIXES[@]}" -eq 0 ] && return 0
  local name="${1,,}" s
  for s in "${ASSET_SUFFIXES[@]}"; do
    [[ "$name" == *"${s,,}" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# GUI: pick tool, selection dialog, progress window
# ---------------------------------------------------------------------------
GUI_TOOL=""
case "$DIALOG_TOOL" in
  zenity)  command -v zenity  >/dev/null && GUI_TOOL=zenity ;;
  kdialog) command -v kdialog >/dev/null && GUI_TOOL=kdialog ;;
  *)       if   command -v zenity  >/dev/null; then GUI_TOOL=zenity
           elif command -v kdialog >/dev/null; then GUI_TOOL=kdialog; fi ;;
esac
if [ -z "$GUI_TOOL" ]; then
  echo "Install zenity or kdialog for the dialogs (sudo dnf install zenity)."
  exit 1
fi

# Shows a checklist dialog and fills SELECTED.
select_repos() {
  local title="$1" u out
  SELECTED=()
  if [ "$GUI_TOOL" = kdialog ]; then
    local state="off" args=() geo=()
    [ "$DEFAULT_CHECKED" = "TRUE" ] && state="on"
    # --geometry is honoured on X11 only; Wayland ignores it (zenity has no such limit).
    if kdialog --help-all 2>&1 | grep -q -- '--geometry'; then
      geo=(--geometry "${DIALOG_WIDTH}x${DIALOG_HEIGHT}")
    fi
    for u in "${REPOS[@]}"; do
      args+=("$u" "${u#https://github.com/}" "$state")
    done
    out="$(kdialog ${geo[@]+"${geo[@]}"} --title "$title" --separate-output \
      --checklist "Select repositories:" "${args[@]}")" || exit 0
  else
    local args=()
    for u in "${REPOS[@]}"; do
      args+=("$DEFAULT_CHECKED" "$u")
    done
    out="$(zenity --list --checklist --title="$title" \
      --text="Select repositories (${#REPOS[@]} available):" \
      --column="Pick" --column="Repository URL" --print-column=2 --separator=$'\n' \
      --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" "${args[@]}")" || exit 0
  fi
  [ -z "$out" ] && { echo "Nothing selected."; exit 0; }
  mapfile -t SELECTED <<<"$out"
}

PROG_ON=0; ZPID=""; ZFIFO=""; QDBUS=""; KD_SVC=""; KD_PATH=""
trap '' PIPE

kd_set_value() {
  if [ -n "$QDBUS" ]; then "$QDBUS" "$KD_SVC" "$KD_PATH" Set "" value "$1" >/dev/null 2>&1
  else dbus-send --session --type=method_call --dest="$KD_SVC" "$KD_PATH" \
         org.freedesktop.DBus.Properties.Set string:org.kde.kdialog.ProgressDialog \
         string:value "variant:int32:$1" >/dev/null 2>&1; fi
}
kd_set_label() {
  if [ -n "$QDBUS" ]; then "$QDBUS" "$KD_SVC" "$KD_PATH" setLabelText "$1" >/dev/null 2>&1
  else dbus-send --session --type=method_call --dest="$KD_SVC" "$KD_PATH" \
         org.kde.kdialog.ProgressDialog.setLabelText "string:$1" >/dev/null 2>&1; fi
}
kd_cancelled() {
  local r
  if [ -n "$QDBUS" ]; then r="$("$QDBUS" "$KD_SVC" "$KD_PATH" wasCancelled 2>/dev/null)"
  else r="$(dbus-send --session --print-reply --type=method_call --dest="$KD_SVC" "$KD_PATH" \
         org.kde.kdialog.ProgressDialog.wasCancelled 2>/dev/null)"; r="${r##* }"; fi
  [ "$r" = "true" ]
}
kd_close() {
  if [ -n "$QDBUS" ]; then "$QDBUS" "$KD_SVC" "$KD_PATH" close >/dev/null 2>&1
  else dbus-send --session --type=method_call --dest="$KD_SVC" "$KD_PATH" \
         org.kde.kdialog.ProgressDialog.close >/dev/null 2>&1; fi
}

progress_start() {
  local title="$1" q ref
  if [ "$GUI_TOOL" = zenity ]; then
    ZFIFO="$(mktemp -u "${TMPDIR:-/tmp}/dlprog.XXXXXX")"
    mkfifo "$ZFIFO" || return 0
    zenity --progress --title="$title" --text="Starting..." --percentage=0 \
      --no-markup --width=680 <"$ZFIFO" >/dev/null 2>&1 &
    ZPID=$!
    exec 3<>"$ZFIFO"
    sleep 0.4
    kill -0 "$ZPID" 2>/dev/null || { echo "(progress window could not open - continuing in console only)"; exec 3>&-; return 0; }
    PROG_ON=1
  else
    for q in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
      command -v "$q" >/dev/null && { QDBUS="$q"; break; }
    done
    if [ -z "$QDBUS" ] && ! command -v dbus-send >/dev/null; then
      echo "(no qdbus/dbus-send found - progress window disabled, console only)"; return 0
    fi
    ref="$(kdialog --title "$title" --progressbar "Starting..." 100 2>/dev/null)" || return 0
    read -r KD_SVC KD_PATH <<<"$ref"
    [ -n "$KD_SVC" ] || return 0
    if [ -n "$QDBUS" ]; then "$QDBUS" "$KD_SVC" "$KD_PATH" showCancelButton true >/dev/null 2>&1
    else dbus-send --session --type=method_call --dest="$KD_SVC" "$KD_PATH" \
           org.kde.kdialog.ProgressDialog.showCancelButton boolean:true >/dev/null 2>&1; fi
    PROG_ON=1
  fi
}

# progress_update <percent> <text>   -> returns 1 if the user pressed Cancel
progress_update() {
  [ "$PROG_ON" = 1 ] || return 0
  local pct=$1 text=$2
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  if [ "$GUI_TOOL" = zenity ]; then
    kill -0 "$ZPID" 2>/dev/null || return 1
    printf '%s\n# %s\n' "$pct" "${text//$'\n'/\\n}" >&3
  else
    kd_set_value "$pct"; kd_set_label "$text"
    kd_cancelled && return 1
  fi
  return 0
}

progress_stop() {
  [ "$PROG_ON" = 1 ] || return 0
  PROG_ON=0
  if [ "$GUI_TOOL" = zenity ]; then
    exec 3>&-
    if [ -n "$ZPID" ]; then sleep 0.2; kill "$ZPID" 2>/dev/null; wait "$ZPID" 2>/dev/null; fi
    rm -f "$ZFIFO"
  else
    kd_close
  fi
}

# ---------------------------------------------------------------------------
# Run state, cleanup, summary
# ---------------------------------------------------------------------------
N=0; TMP=""; CURL_PID=""; CUR_PART=""
TOTAL_BYTES=0; TOTAL_FILES=0; DONE_BYTES=0; FILES_OK=0; FILES_SKIPPED=0; FILES_FAILED=0
DONE_REPOS=(); SKIPPED_REPOS=(); FAILED_ITEMS=(); FOLDERS=()
RUN_START=$SECONDS; DL_START_US=0

cleanup() {
  trap - EXIT
  [ -n "$CURL_PID" ] && kill "$CURL_PID" 2>/dev/null
  [ -n "$CUR_PART" ] && rm -f "$CUR_PART"
  progress_stop
  [ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

summary() {
  local el=$((SECONDS-RUN_START)) avg=0 f
  [ "$el" -gt 0 ] && avg=$((DONE_BYTES/el))
  echo
  echo "================ Summary ================"
  echo " Files downloaded : $FILES_OK  ($(human_bytes "$DONE_BYTES"))"
  echo " Already present  : $FILES_SKIPPED"
  echo " Failed           : $FILES_FAILED"
  echo " Time / avg speed : $(fmt_time "$el")  /  $(human_bytes "$avg")/s"
  if [ "${#FOLDERS[@]}" -gt 0 ]; then
    echo " Saved in:"
    for f in "${FOLDERS[@]}"; do echo "   $f"; done
  fi
  if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
    echo " Failed items:"
    for f in "${FAILED_ITEMS[@]}"; do echo "   $f"; done
  fi
  echo "========================================="
}

cancel_exit() {
  echo; echo "Cancelled."
  summary
  exit 130
}

# Builds the progress text and updates GUI + console (called while a file downloads)
# uses: i N repo rel_name fidx fcount file sz size spd
release_ui() {
  local cur=$((DONE_BYTES + sz)) pct=0 fpct=0 now el eta="--:--:--" avg text
  [ "$TOTAL_BYTES" -gt 0 ] && pct=$((cur*100/TOTAL_BYTES))
  [ "$size" -gt 0 ] && fpct=$((sz*100/size))
  [ "$pct" -gt 100 ] && pct=100
  [ "$fpct" -gt 100 ] && fpct=100
  now=${EPOCHREALTIME/[.,]/}
  el=$(( (now - DL_START_US) / 1000000 ))
  if [ "$el" -ge 2 ] && [ "$cur" -gt 0 ]; then
    avg=$((cur/el))
    [ "$avg" -gt 0 ] && eta="$(fmt_time $(( (TOTAL_BYTES-cur) / avg )))"
  fi
  printf -v text '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "Repository $((i+1)) of $N:  $repo   (release: $rel_name)" \
    "File $fidx of $fcount:  $file" \
    "This file:  ${fpct}%   ($(human_bytes "$sz") / $(human_bytes "$size"))" \
    "Speed:  $(human_bytes "$spd")/s        ETA (all):  $eta" \
    "Overall:  $(human_bytes "$cur") / $(human_bytes "$TOTAL_BYTES")   (${pct}%)        Elapsed: $(fmt_time $((SECONDS-RUN_START)))" \
    "Finished repos (${#DONE_REPOS[@]}):  $(tail_list DONE_REPOS)" \
    "Skipped (no release / no matching files) (${#SKIPPED_REPOS[@]}):  $(tail_list SKIPPED_REPOS)" \
    "Failed files: $FILES_FAILED"
  progress_update "$pct" "$text" || cancel_exit
  if [ -t 1 ]; then
    printf '\r\033[K  %s %3d%%  %s / %s  %s/s  ETA %s' "$(bar "$fpct" 16)" "$fpct" \
      "$(human_bytes "$sz")" "$(human_bytes "$size")" "$(human_bytes "$spd")" "$eta"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
select_repos "Download latest releases"
N=${#SELECTED[@]}
TMP="$(mktemp -d)"
mkdir -p "$OUT_DIR"
progress_start "Download latest releases"

declare -a R_PATH R_SHORT R_REL R_FOLDER R_STATE R_COUNT

# ---- Phase 1: look up every release first (so we know the total size) ----
echo "Checking latest releases ($N repos)..."
for ((i=0; i<N; i++)); do
  url="${SELECTED[i]}"
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  R_PATH[i]="$owner/$repo"; R_SHORT[i]="$repo"; R_REL[i]=""; R_FOLDER[i]=""
  R_STATE[i]="norelease"; R_COUNT[i]=0

  progress_update 0 "Checking releases ($((i+1)) of $N)..."$'\n'"$owner/$repo" || cancel_exit

  # /releases/latest returns the newest published release (not drafts or pre-releases)
  json="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$owner/$repo/releases/latest")" \
    || { log "  ! $owner/$repo: no latest release found or API error"; continue; }

  name="$(jq -r '.name // empty' <<<"$json")"
  [ -z "$name" ] && name="$(jq -r '.tag_name' <<<"$json")"
  folder="$OUT_DIR/$(sanitize "$name")"
  R_REL[i]="$name"; R_FOLDER[i]="$folder"

  total="$(jq '.assets | length' <<<"$json")"
  if [ "$total" -eq 0 ]; then
    R_STATE[i]="noassets"; log "  $owner/$repo: release '$name' has no attached files"; continue
  fi

  : > "$TMP/$i.assets"
  nm=0
  while IFS=$'\t' read -r file dl size; do
    want_asset "$file" || continue
    printf '%s\t%s\t%s\n' "$file" "$dl" "$size" >> "$TMP/$i.assets"
    nm=$((nm+1))
    # already fully downloaded? then it does not count towards the total
    if [ -f "$folder/$file" ] && [ "$(stat -c%s "$folder/$file")" = "$size" ]; then continue; fi
    TOTAL_BYTES=$((TOTAL_BYTES + size)); TOTAL_FILES=$((TOTAL_FILES + 1))
  done < <(jq -r '.assets[] | [.name, .browser_download_url, (.size|tostring)] | @tsv' <<<"$json")

  R_COUNT[i]=$nm
  if [ "$nm" -eq 0 ]; then
    R_STATE[i]="nomatch"; log "  $owner/$repo: none of the $total assets matched ASSET_SUFFIXES"
  else
    R_STATE[i]="ready";   log "  $owner/$repo: '$name' - $nm matching file(s)"
  fi
done
echo
echo "To download: $TOTAL_FILES file(s), $(human_bytes "$TOTAL_BYTES") in total"
echo

# ---- Phase 2: download ----
DL_START_US=${EPOCHREALTIME/[.,]/}
for ((i=0; i<N; i++)); do
  repo="${R_SHORT[i]}"; rel_name="${R_REL[i]}"; folder="${R_FOLDER[i]}"
  echo "== ${R_PATH[i]}"
  case "${R_STATE[i]}" in
    norelease) log "  ! no latest release found or API error"; SKIPPED_REPOS+=("$repo"); continue ;;
    noassets)  log "  no attached files in this release";        SKIPPED_REPOS+=("$repo"); continue ;;
    nomatch)   log "  ! none of the assets matched ASSET_SUFFIXES"; SKIPPED_REPOS+=("$repo"); continue ;;
  esac
  echo "  release: $rel_name"

  fcount="${R_COUNT[i]}"; fidx=0; repo_failed=0
  while IFS=$'\t' read -r -u 4 file dl size; do
    fidx=$((fidx+1))
    mkdir -p "$folder"
    if [ -f "$folder/$file" ] && [ "$(stat -c%s "$folder/$file")" = "$size" ]; then
      log "  already exists, skipping: $file"; FILES_SKIPPED=$((FILES_SKIPPED+1)); continue
    fi
    log "  downloading: $file ($(human_bytes "$size"))"

    CUR_PART="$folder/$file.part"; rm -f "$CUR_PART"
    curl -fL -sS ${AUTH[@]+"${AUTH[@]}"} -o "$CUR_PART" "$dl" 2>"$TMP/curl.err" &
    CURL_PID=$!
    last_sz=0; last_t=${EPOCHREALTIME/[.,]/}; spd=0; sz=0; file_t0=$last_t
    while kill -0 "$CURL_PID" 2>/dev/null; do
      sz="$(stat -c%s "$CUR_PART" 2>/dev/null || echo 0)"
      t=${EPOCHREALTIME/[.,]/}; dt=$((t - last_t))
      if [ "$dt" -ge 400000 ]; then
        inst=$(( (sz - last_sz) * 1000000 / dt ))
        if [ "$spd" -eq 0 ]; then spd=$inst; else spd=$(( (spd*6 + inst*4) / 10 )); fi
        last_sz=$sz; last_t=$t
      fi
      release_ui
      sleep 0.5
    done
    wait "$CURL_PID"; rc=$?
    CURL_PID=""

    if [ "$rc" -eq 0 ] && [ -f "$CUR_PART" ]; then
      mv -f "$CUR_PART" "$folder/$file"; CUR_PART=""
      sz="$size"
      secs=$(( ( ${EPOCHREALTIME/[.,]/} - file_t0 ) / 1000000 )); [ "$secs" -lt 1 ] && secs=1
      release_ui                      # show 100% for this file ...
      DONE_BYTES=$((DONE_BYTES + size)); FILES_OK=$((FILES_OK+1))   # ... then count it as done
      log "  done: $file  (avg $(human_bytes $((size/secs)))/s)"
    else
      log "  ! failed: $file  $(head -c 200 "$TMP/curl.err" 2>/dev/null)"
      rm -f "$CUR_PART"; CUR_PART=""
      FILES_FAILED=$((FILES_FAILED+1)); repo_failed=1
      FAILED_ITEMS+=("$repo: $file")
    fi
  done 4< "$TMP/$i.assets"

  FOLDERS+=("$folder")
  [ "$repo_failed" -eq 0 ] && DONE_REPOS+=("$repo")
  echo "  matched $fcount file(s) -> $folder"
done

# ---- Finish ----
summary
if [ "$PROG_ON" = 1 ]; then
  progress_update 100 "Finished!"$'\n'"Downloaded $FILES_OK file(s), $(human_bytes "$DONE_BYTES") in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Saved in: $OUT_DIR" >/dev/null
  sleep 2
fi
echo "Done."
command -v notify-send >/dev/null && notify-send "Release download finished" "$FILES_OK file(s), $(human_bytes "$DONE_BYTES") - $N repo(s) processed"

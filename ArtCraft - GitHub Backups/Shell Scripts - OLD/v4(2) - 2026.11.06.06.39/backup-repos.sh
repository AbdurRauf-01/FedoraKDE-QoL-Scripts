#!/usr/bin/env bash
# Full git mirror + repo metadata + issues + pull requests (with comments and reviews).
# No wiki, no releases. Output: ~/Downloads/"yyyy.MM.dd.HH.mm.ss - repo.zip"
#  - Opens its own console window when started from a launcher / file manager.
#  - A (bigger) selection dialog opens on launch; all repos are ticked by default.
#  - A GUI progress window shows the current repo + step, speed, data fetched,
#    ETA and the repos that are already finished. Cancel it (or Ctrl+C) to stop.
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

DEFAULT_CHECKED="TRUE"   # TRUE = all ticked on launch, FALSE = none ticked

# Dialog look: auto = zenity if installed (its size is fully controllable),
# otherwise kdialog. Force one with: zenity | kdialog
DIALOG_TOOL="auto"
DIALOG_WIDTH=900
DIALOG_HEIGHT=800

OUT_DIR="$HOME/Downloads"
TOKEN_FILE="$HOME/.config/github-token"
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

AUTH=()
GIT_AUTH=()
if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
  GIT_AUTH=(-c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)")
fi

for cmd in git curl jq zip awk du; do
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
N=0; IDX=0; CUR_REPO=""; STAGE=""; DETAIL=""; FRAC_PM=0; ISSUES="?"; PRS="?"
CUR_WORK=""; CUR_OUT=""; CHILD_PID=""; MEASURE_PATH=""
CUR_BYTES=0; PREV_BYTES=0; LAST_BYTES=0; SPEED=0; LAST_UI_US=0
DONE_REPOS=(); FAILED_REPOS=(); SAVED=()
RUN_START=$SECONDS

cleanup() {
  trap - EXIT
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
  [ -n "$CUR_OUT" ] && rm -f "$CUR_OUT"
  progress_stop
  [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

summary() {
  local el=$((SECONDS-RUN_START)) f
  echo
  echo "================ Summary ================"
  echo " Repos saved    : ${#DONE_REPOS[@]} of $N"
  echo " Repos failed   : ${#FAILED_REPOS[@]}"
  echo " Data fetched   : $(human_bytes "$PREV_BYTES")"
  echo " Total time     : $(fmt_time "$el")"
  if [ "${#SAVED[@]}" -gt 0 ]; then
    echo " Zip files:"
    for f in "${SAVED[@]}"; do echo "   $f"; done
  fi
  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
    echo " Failed:"
    for f in "${FAILED_REPOS[@]}"; do echo "   $f"; done
  fi
  echo "========================================="
}

cancel_exit() {
  echo; echo "Cancelled."
  summary
  exit 130
}

# Updates speed + GUI + console. Rate-limited to twice a second unless forced.
ui_refresh() {
  local force="${1:-}" t dt inst pm el eta="--:--:--" text out
  t=${EPOCHREALTIME/[.,]/}
  dt=$((t - LAST_UI_US))
  [ -z "$force" ] && [ "$dt" -lt 500000 ] && return 0

  if [ -n "$MEASURE_PATH" ] && [ -d "$MEASURE_PATH" ]; then
    out="$(du -sb "$MEASURE_PATH" 2>/dev/null | cut -f1)"; CUR_BYTES=${out:-0}
    if [ "$LAST_UI_US" -gt 0 ] && [ "$dt" -gt 0 ]; then
      inst=$(( (CUR_BYTES - LAST_BYTES) * 1000000 / dt )); [ "$inst" -lt 0 ] && inst=0
      SPEED=$(( (SPEED*6 + inst*4) / 10 ))
    fi
    LAST_BYTES=$CUR_BYTES
  else
    SPEED=0
  fi
  LAST_UI_US=$t

  # overall progress in permille: finished repos + fraction of the current one
  pm=$(( ((IDX-1)*1000 + FRAC_PM) / N ))
  [ "$pm" -gt 1000 ] && pm=1000
  el=$((SECONDS - RUN_START))
  if [ "$pm" -ge 20 ] && [ "$el" -ge 3 ]; then eta="~$(fmt_time $(( el * (1000-pm) / pm )))"; fi

  printf -v text '%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "Repository $IDX of $N:  $CUR_REPO" \
    "Step:  $STAGE${DETAIL:+   ($DETAIL)}" \
    "Speed:  $(human_bytes "$SPEED")/s        Fetched so far:  $(human_bytes $((PREV_BYTES + CUR_BYTES)))" \
    "This repo:  issues $ISSUES,  pull requests $PRS" \
    "Elapsed:  $(fmt_time "$el")        ETA (estimate):  $eta" \
    "Finished (${#DONE_REPOS[@]}):  $(tail_list DONE_REPOS)" \
    "Failed (${#FAILED_REPOS[@]}):  $(tail_list FAILED_REPOS)"
  progress_update $((pm/10)) "$text" || cancel_exit
  if [ -t 1 ]; then
    printf '\r\033[K  %s %3d%%  %s  %s/s  %s' "$(bar $((pm/10)) 16)" $((pm/10)) \
      "$(human_bytes $((PREV_BYTES + CUR_BYTES)))" "$(human_bytes "$SPEED")" "$STAGE"
  fi
}

# Fetch every page of a list endpoint and write one merged JSON array to a file.
# $1 = endpoint URL, $2 = optional query string (e.g. "state=all"), $3 = output file
api_get_all() {
  local url="$1" extra="${2:-}" out="$3" page=1 tmp resp
  tmp="$(mktemp)"
  while :; do
    resp="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
      "${url}?${extra:+$extra&}per_page=100&page=${page}")" \
      || { log "  ! API error: $url (page $page)"; break; }
    [ "$(jq 'length' <<<"$resp")" -eq 0 ] && break
    printf '%s\n' "$resp" >> "$tmp"
    page=$((page + 1))
    ui_refresh
  done
  jq -s 'add // []' "$tmp" > "$out"
  rm -f "$tmp"
}

finish_repo() {   # fold this repo's bytes into the running total
  PREV_BYTES=$((PREV_BYTES + CUR_BYTES)); CUR_BYTES=0; LAST_BYTES=0
  MEASURE_PATH=""; [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"; CUR_WORK=""
}

backup_repo() {
  local url="$1" path owner repo api work dest ts out est_kb est f i n total c rc zt
  local line gpid zpid
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  api="https://api.github.com/repos/$owner/$repo"
  echo "== $owner/$repo"

  IDX=$((IDX+1)); CUR_REPO="$owner/$repo"; ISSUES="?"; PRS="?"
  STAGE="Preparing"; DETAIL=""; FRAC_PM=0; SPEED=0; LAST_BYTES=0; CUR_BYTES=0
  CUR_WORK="$(mktemp -d)"; work="$CUR_WORK"
  dest="$work/$repo"; mkdir -p "$dest"
  MEASURE_PATH="$work"
  ui_refresh force

  # 1. Repo metadata (description, topics, settings, size estimate, etc.)
  STAGE="Reading repository metadata"; FRAC_PM=10; ui_refresh force
  curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" "$api" \
    > "$dest/repo.json" || log "  ! repo metadata failed"
  est_kb="$(jq -r '.size // 0' "$dest/repo.json" 2>/dev/null)"
  [[ "$est_kb" =~ ^[0-9]+$ ]] || est_kb=0

  # 2. Full git mirror: all branches, tags, and pull request refs
  est=$((est_kb * 1024)); [ "$est" -lt 1048576 ] && est=1048576
  STAGE="Cloning git mirror"
  DETAIL="repo size ~ $(human_bytes $((est_kb * 1024)))"
  FRAC_PM=30; ui_refresh force
  git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} clone --mirror --quiet \
    "https://github.com/$owner/$repo.git" "$dest/git-mirror.git" &
  gpid=$!; CHILD_PID=$gpid
  while kill -0 "$gpid" 2>/dev/null; do
    f=$(( CUR_BYTES * 1000 / est )); [ "$f" -gt 970 ] && f=970
    FRAC_PM=$(( 30 + f * 670 / 1000 ))
    ui_refresh
    sleep 0.5
  done
  wait "$gpid"; rc=$?; CHILD_PID=""
  DETAIL=""
  if [ "$rc" -ne 0 ]; then
    log "  ! git clone failed"
    FAILED_REPOS+=("$owner/$repo"); finish_repo; return
  fi

  # 3. Issues. The issues endpoint also returns PRs, so filter them out.
  STAGE="Fetching issues"; DETAIL="issue list"; FRAC_PM=700; ui_refresh force
  mkdir -p "$dest/issues/comments"
  api_get_all "$api/issues" "state=all" "$dest/issues/all.json"
  jq 'map(select(has("pull_request") | not))' "$dest/issues/all.json" > "$dest/issues/issues.json"
  rm -f "$dest/issues/all.json"
  ISSUES="$(jq length "$dest/issues/issues.json")"
  mapfile -t inums < <(jq -r '.[] | select(.comments > 0) | .number' "$dest/issues/issues.json")
  total=${#inums[@]}; i=0
  for n in ${inums[@]+"${inums[@]}"}; do
    i=$((i+1)); DETAIL="issue comments $i/$total"
    FRAC_PM=$(( 700 + 150 * i / total )); ui_refresh
    api_get_all "$api/issues/$n/comments" "" "$dest/issues/comments/$n.json"
  done
  log "  issues: $ISSUES"

  # 4. Pull requests: details, conversation comments, review comments, reviews.
  #    (The PR *list* does not contain comment counts, so every PR is queried.)
  STAGE="Fetching pull requests"; DETAIL="pull request list"; FRAC_PM=850; ui_refresh force
  mkdir -p "$dest/pulls/conversation" "$dest/pulls/review-comments" "$dest/pulls/reviews"
  api_get_all "$api/pulls" "state=all" "$dest/pulls/pulls.json"
  PRS="$(jq length "$dest/pulls/pulls.json")"
  mapfile -t pnums < <(jq -r '.[].number' "$dest/pulls/pulls.json")
  total=${#pnums[@]}; i=0
  for n in ${pnums[@]+"${pnums[@]}"}; do
    i=$((i+1)); DETAIL="PR #$n  ($i/$total)"
    FRAC_PM=$(( 850 + 120 * i / total )); ui_refresh
    api_get_all "$api/issues/$n/comments" "" "$dest/pulls/conversation/$n.json"
    api_get_all "$api/pulls/$n/comments"  "" "$dest/pulls/review-comments/$n.json"
    api_get_all "$api/pulls/$n/reviews"   "" "$dest/pulls/reviews/$n.json"
    # drop empty files to keep the archive tidy
    for c in conversation review-comments reviews; do
      [ "$(jq length "$dest/pulls/$c/$n.json" 2>/dev/null)" = "0" ] && rm -f "$dest/pulls/$c/$n.json"
    done
  done
  log "  pull requests: $PRS"

  # 5. Zip into Downloads with a timestamp name
  DETAIL=""; STAGE="Compressing to zip"; FRAC_PM=970; ui_refresh force
  MEASURE_PATH=""          # stop measuring (no network traffic while zipping)
  ts="$(date +"%Y.%m.%d.%H.%M.%S")"
  out="$OUT_DIR/$ts - $repo.zip"; CUR_OUT="$out"
  pushd "$work" >/dev/null
  zip -qr "$out" "$repo" &
  zpid=$!; CHILD_PID=$zpid; zt=0
  while kill -0 "$zpid" 2>/dev/null; do
    zt=$((zt+1)); FRAC_PM=$(( 970 + 28 - 28 * 20 / (20 + zt) ))
    ui_refresh
    sleep 0.5
  done
  wait "$zpid"; rc=$?; CHILD_PID=""
  popd >/dev/null
  if [ "$rc" -eq 0 ]; then
    log "  saved: $out  ($(human_bytes "$(stat -c%s "$out")"))"
    SAVED+=("$out"); DONE_REPOS+=("$repo")
  else
    log "  ! zip failed"; rm -f "$out"; FAILED_REPOS+=("$owner/$repo")
  fi
  CUR_OUT=""
  FRAC_PM=1000; ui_refresh force
  finish_repo
}

select_repos "Backup repositories"
N=${#SELECTED[@]}
mkdir -p "$OUT_DIR"
progress_start "Backup repositories"

for url in "${SELECTED[@]}"; do
  backup_repo "$url"
done

summary
if [ "$PROG_ON" = 1 ]; then
  progress_update 100 "Finished!"$'\n'"${#DONE_REPOS[@]} of $N repo(s) saved in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Saved in: $OUT_DIR" >/dev/null
  sleep 2
fi
echo "Done."
command -v notify-send >/dev/null && notify-send "Repo backup finished" "${#DONE_REPOS[@]} of $N repo(s) saved to $OUT_DIR"

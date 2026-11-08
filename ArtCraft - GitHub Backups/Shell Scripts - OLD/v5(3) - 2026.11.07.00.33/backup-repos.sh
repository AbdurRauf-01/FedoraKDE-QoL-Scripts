#!/usr/bin/env bash
# Backs up selected GitHub repos into one zip each: full git mirror (all branches,
# tags, PR refs) + repo info + issues + pull requests with all comments and reviews.
# No wiki, no releases. Output: ~/Downloads/"yyyy.MM.dd.HH.mm.ss - repo.zip"
#  - Opens its own console window when started from a launcher / file manager.
#  - A selection dialog opens on launch; all repos are ticked by default.
#  - A GUI progress window shows the current repo + step, speed, data fetched,
#    ETA and the repos that are already finished. Cancel it (or Ctrl+C) to stop.
#  - Options: --all (no dialog, every repo)   --no-gui (no progress window)
set -u

# ---------------------------------------------------------------------------
# Open a console window if we were started without a terminal (double-click)
# ---------------------------------------------------------------------------
if [ ! -t 1 ] && [ -z "${REPO_TOOL_IN_TERM:-}" ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  export REPO_TOOL_IN_TERM=1
  _self="$(readlink -f "${BASH_SOURCE[0]}")"
  _wrap='bash "$@"; rc=$?; echo; read -r -p "Finished (exit code $rc). Press Enter to close this window... " _'
  for _t in konsole ptyxis gnome-terminal xfce4-terminal mate-terminal alacritty kitty foot xterm; do
    command -v "$_t" >/dev/null 2>&1 || continue
    case "$_t" in
      gnome-terminal|ptyxis) exec "$_t" -- bash -c "$_wrap" _ "$_self" "$@" ;;
      xfce4-terminal|mate-terminal) exec "$_t" -x bash -c "$_wrap" _ "$_self" "$@" ;;
      kitty|foot)    exec "$_t" bash -c "$_wrap" _ "$_self" "$@" ;;
      *)             exec "$_t" -e bash -c "$_wrap" _ "$_self" "$@" ;;
    esac
  done
fi

# ---------------------------------------------------------------------------
# Command line options
# ---------------------------------------------------------------------------
OPT_ALL=0       # --all     : skip the selection dialog and process every repo
OPT_NOGUI=0     # --no-gui  : no progress window (console output only)

usage() {
  cat <<EOF
Usage: ${0##*/} [--all] [--no-gui] [--help]
  --all      skip the repository selection dialog and process every repo in the list
  --no-gui   do not open the GUI progress window (console output only)
  --help     show this text
GitHub token: set GITHUB_TOKEN or put it in ~/.config/github-token
EOF
}

for _a in "$@"; do
  case "$_a" in
    --all)        OPT_ALL=1 ;;
    --no-gui)     OPT_NOGUI=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown option: $_a" >&2; usage >&2; exit 2 ;;
  esac
done

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

DEFAULT_CHECKED="TRUE"    # TRUE = all ticked on launch, FALSE = none ticked

# Dialog look: auto = zenity if installed (its size is fully controllable),
# otherwise kdialog. Force one with: zenity | kdialog
DIALOG_TOOL="auto"
DIALOG_WIDTH=900
DIALOG_HEIGHT=800

# Seconds the final "Finished" text stays in the progress window.
FINISH_LINGER=3

TOKEN_FILE="$HOME/.config/github-token"

OUT_DIR="$HOME/Downloads"

REQUIRED_CMDS=(git curl jq zip awk du stat base64)

# ===========================================================================
# Shared core (identical in all three scripts)
# ===========================================================================
for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

TMP="$(mktemp -d)" || exit 1      # small scratch dir, removed on exit (private: mode 700)

# ---- GitHub token. Kept out of process arguments: curl reads the header from a
#      private file, git gets its header through environment variables.
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"
TOKEN="${TOKEN//[[:space:]]/}"
AUTH=()
GIT_ENV=(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false)   # never hang on a credentials prompt
if [ -n "$TOKEN" ]; then
  printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/auth.hdr"
  AUTH=(-H "@$TMP/auth.hdr")
  GIT_ENV+=(GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=http.extraheader
            "GIT_CONFIG_VALUE_2=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)")
else
  echo "Note: no GitHub token found (GITHUB_TOKEN or $TOKEN_FILE)."
  echo "      The API is then limited to 60 requests/hour and private repos are not reachable."
fi
unset TOKEN

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

repo_parts() {   # repo_parts <url>  -> sets OWNER and REPO
  local p="$1"
  p="${p#https://github.com/}"; p="${p%/}"; p="${p%.git}"
  OWNER="${p%%/*}"; REPO="${p#*/}"
}

# ---------------------------------------------------------------------------
# GitHub API request with retries. gh_request <url> <output-file>
# Sets HTTP_CODE; returns 0 only for HTTP 200. Retries network errors and 5xx.
# ---------------------------------------------------------------------------
HTTP_CODE=000; RATE_LIMITED=0
gh_request() {
  local url="$1" out="$2" try
  for try in 1 2 3; do
    HTTP_CODE="$(curl -sSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
      -D "$TMP/hdr" -o "$out" -w '%{http_code}' "$url" 2>"$TMP/curl.err")" || HTTP_CODE=000
    case "$HTTP_CODE" in
      000|5??) [ "$try" -lt 3 ] && sleep $((try*2)) ;;
      *)       break ;;
    esac
  done
  if { [ "$HTTP_CODE" = 403 ] || [ "$HTTP_CODE" = 429 ]; } && grep -qi '^x-ratelimit-remaining: *0' "$TMP/hdr" 2>/dev/null; then
    RATE_LIMITED=1
  fi
  [ "$HTTP_CODE" = 200 ]
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
if [ -z "$GUI_TOOL" ] && [ "$OPT_ALL" = 0 ]; then
  echo "Install zenity or kdialog for the dialogs (sudo dnf install zenity), or run with --all."
  rm -rf "$TMP"; exit 1
fi

# Shows a checklist dialog and fills SELECTED (or takes every repo with --all).
SELECTED=()
select_repos() {
  local title="$1" u out state="off" rows=() geo=()
  if [ "$OPT_ALL" = 1 ]; then SELECTED=("${REPOS[@]}"); return; fi
  [ "$DEFAULT_CHECKED" = "TRUE" ] && state="on"
  if [ "$GUI_TOOL" = zenity ]; then
    for u in "${REPOS[@]}"; do rows+=("$DEFAULT_CHECKED" "${u#https://github.com/}" "$u"); done
    out="$(zenity --list --checklist --title="$title" \
      --text="Tick the repositories to process (${#REPOS[@]} available), then press OK:" \
      --column="Pick" --column="Repository" --column="URL" \
      --hide-column=3 --print-column=3 --separator=$'\n' \
      --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" "${rows[@]}")" || exit 0
  else
    # --geometry is honoured on X11 only (Wayland ignores it); only pass it if this
    # kdialog build knows the option, an unknown option would abort the dialog.
    if kdialog --help-all 2>&1 | grep -q -- '--geometry'; then
      geo=(--geometry "${DIALOG_WIDTH}x${DIALOG_HEIGHT}")
    fi
    for u in "${REPOS[@]}"; do rows+=("$u" "${u#https://github.com/}" "$state"); done
    out="$(kdialog ${geo[@]+"${geo[@]}"} --title "$title" --separate-output \
      --checklist "Tick the repositories to process:" "${rows[@]}")" || exit 0
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
  [ "$OPT_NOGUI" = 1 ] && return 0
  [ -z "$GUI_TOOL" ] && return 0
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
    text="${text//\\/\\\\}"; text="${text//$'\n'/\\n}"
    printf '%s\n# %s\n' "$pct" "$text" >&3
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

# Shows the final text in the progress window for a moment.
finish_ui() {   # finish_ui <text>
  [ "$PROG_ON" = 1 ] || return 0
  progress_update 100 "$1" >/dev/null
  sleep "$FINISH_LINGER"
}

# ---------------------------------------------------------------------------
# Run state, cleanup, signals
# ---------------------------------------------------------------------------
CHILD_PID=""
RUN_START=$SECONDS
on_cleanup() { :; }      # each script overrides this with its own temp-file cleanup

cleanup() {
  trap - EXIT
  if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; fi
  on_cleanup
  progress_stop
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM HUP

cancel_exit() {
  echo; echo "Cancelled."
  summary
  exit 130
}

# ---------------------------------------------------------------------------
# Zip a work folder.
# Right after a clone / fetch git can still be tidying up inside .git (lock files,
# temporary packs, automatic maintenance). If a file disappears while zip is reading
# the folder, zip stops with "No such file or directory" (exit code 18). So:
#   - git's automatic maintenance is switched off for our git commands (see GIT_ENV),
#   - we wait until no lock file or temporary pack is left in the git folder,
#   - and if files still vanish, zip is retried (3 attempts), naming the vanished files.
# Symlinks are stored as links (-y) instead of being followed.
# make_zip <work-dir> <entry> <output-zip> <git-dir> <progress-base-permille> <progress-span-permille>
# Returns 0 on success; ZIP_LOST holds the first vanished files if it kept failing.
# ---------------------------------------------------------------------------
ZIP_LOST=""

wait_git_quiet() {   # wait up to 30 s until the git folder holds no lock file / temporary pack
  local d="$1" i
  [ -d "$d" ] || return 0
  for i in $(seq 1 30); do
    [ -z "$(find "$d" \( -name '*.lock' -o -name 'gc.pid' -o -name 'tmp_*' \) -print -quit 2>/dev/null)" ] && return 0
    sleep 1
  done
  return 0
}

make_zip() {
  local work="$1" entry="$2" out="$3" gitdir="$4" base="$5" span="$6" attempt rc zpid zt
  ZIP_LOST=""
  for attempt in 1 2 3; do
    wait_git_quiet "$gitdir"
    find "$work/$entry" -mindepth 1 2>/dev/null | sort > "$TMP/zip.before"
    rm -f "$out"
    ( cd "$work" && exec zip -qry "$out" "$entry" 2>"$TMP/zip.err" ) &
    zpid=$!; CHILD_PID=$zpid; zt=0
    while kill -0 "$zpid" 2>/dev/null; do
      zt=$((zt+1)); FRAC_PM=$(( base + span - span * 20 / (20 + zt) ))
      ui_refresh
      sleep 0.5
    done
    wait "$zpid"; rc=$?; CHILD_PID=""
    if [ "$rc" -eq 0 ] && command -v unzip >/dev/null && ! unzip -tqq "$out" >/dev/null 2>&1; then rc=1; fi
    [ "$rc" -eq 0 ] && return 0

    # which files were in the folder before zipping but are gone now?
    find "$work/$entry" -mindepth 1 2>/dev/null | sort > "$TMP/zip.after"
    ZIP_LOST="$(comm -23 "$TMP/zip.before" "$TMP/zip.after" | head -n 5 | sed "s|^$work/||" | tr '\n' ' ')"
    if [ "$rc" -eq 18 ] && [ "$attempt" -lt 3 ]; then
      log "  ! zip could not read some files (exit 18${ZIP_LOST:+, vanished: $ZIP_LOST}) - trying again ($((attempt+1)) of 3)"
      sleep 3; continue
    fi
    break
  done
  rm -f "$out"
  return "$rc"
}

# ===========================================================================
# Backup
# ===========================================================================
N=0; IDX=0; CUR_REPO=""; STAGE=""; DETAIL=""; FRAC_PM=0; ISSUES="?"; PRS="?"
CUR_WORK=""; CUR_OUT=""; MEASURE_PATH=""
CUR_BYTES=0; PREV_BYTES=0; LAST_BYTES=0; SPEED=0; LAST_UI_US=0
API_FAIL=0
DONE_REPOS=(); FAILED_REPOS=(); WARN_REPOS=(); SAVED=()

on_cleanup() {
  [ -n "$CUR_OUT" ] && rm -f "$CUR_OUT"
  [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"
}

summary() {
  local el=$((SECONDS-RUN_START)) f
  echo
  echo "================ Summary ================"
  echo " Repos saved    : ${#DONE_REPOS[@]} of $N"
  echo " With warnings  : ${#WARN_REPOS[@]}"
  echo " Repos failed   : ${#FAILED_REPOS[@]}"
  echo " Data fetched   : $(human_bytes "$PREV_BYTES")"
  echo " Total time     : $(fmt_time "$el")"
  if [ "${#SAVED[@]}" -gt 0 ]; then
    echo " Zip files:"
    for f in "${SAVED[@]}"; do echo "   $f"; done
  fi
  if [ "${#WARN_REPOS[@]}" -gt 0 ]; then
    echo " Saved, but some GitHub API data is missing (see messages above):"
    for f in "${WARN_REPOS[@]}"; do echo "   $f"; done
  fi
  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
    echo " Failed:"
    for f in "${FAILED_REPOS[@]}"; do echo "   $f"; done
  fi
  if [ "$RATE_LIMITED" = 1 ]; then
    echo " The GitHub API rate limit was hit - set GITHUB_TOKEN (or ~/.config/github-token) and run again."
  fi
  echo "========================================="
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
# Counts a problem in API_FAIL (so the repo is flagged) unless the feature is simply
# disabled for the repo (HTTP 410, e.g. issues switched off).
api_get_all() {
  local url="$1" extra="${2:-}" out="$3" page=1 n
  : > "$TMP/pages"
  if [ "$RATE_LIMITED" = 1 ]; then
    API_FAIL=$((API_FAIL + 1)); echo '[]' > "$out"; return 0
  fi
  while :; do
    if ! gh_request "${url}?${extra:+$extra&}per_page=100&page=${page}" "$TMP/body"; then
      [ "$HTTP_CODE" = 410 ] && break
      if [ "$RATE_LIMITED" = 1 ]; then
        log "  ! GitHub API rate limit reached - the rest of this run will lack issue/PR data (use a token)"
      else
        log "  ! API error HTTP $HTTP_CODE: $url (page $page)"
      fi
      API_FAIL=$((API_FAIL + 1)); break
    fi
    if ! n="$(jq 'length' "$TMP/body" 2>/dev/null)"; then
      log "  ! unexpected API answer: $url (page $page)"; API_FAIL=$((API_FAIL + 1)); break
    fi
    [ "$n" -eq 0 ] && break
    cat "$TMP/body" >> "$TMP/pages"; echo >> "$TMP/pages"
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
    ui_refresh
  done
  jq -s 'add // []' "$TMP/pages" > "$out"
}

# Splits a merged comment array into one <number>.json per issue / pull request.
# $1 = merged JSON file, $2 = field holding ".../<number>" (issue_url / pull_request_url),
# $3 = output directory
split_by_number() {
  local src="$1" field="$2" outdir="$3" n json
  mkdir -p "$outdir"
  jq -r --arg f "$field" \
    'group_by(.[$f] // "")[] | ((.[0][$f] // "" | split("/") | last) + "\t" + tojson)' "$src" |
  while IFS=$'\t' read -r n json; do
    [ -n "$n" ] && printf '%s\n' "$json" | jq . > "$outdir/$n.json"
  done
}

finish_repo() {   # fold this repo's bytes into the running total
  PREV_BYTES=$((PREV_BYTES + CUR_BYTES)); CUR_BYTES=0; LAST_BYTES=0
  MEASURE_PATH=""; [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"; CUR_WORK=""
}

backup_repo() {
  local url="$1" api work dest ts out est_kb est f i n total rc zt gpid zpid
  local inums=() pnums=()
  repo_parts "$url"; local owner="$OWNER" repo="$REPO"
  api="https://api.github.com/repos/$owner/$repo"
  echo "== $owner/$repo"

  IDX=$((IDX+1)); CUR_REPO="$owner/$repo"; ISSUES="?"; PRS="?"; API_FAIL=0
  STAGE="Preparing"; DETAIL=""; FRAC_PM=0; SPEED=0; LAST_BYTES=0; CUR_BYTES=0
  # work inside the output folder, not /tmp (which can be a small RAM disk)
  CUR_WORK="$(mktemp -d "$OUT_DIR/.backup-work.XXXXXX")" || { log "  ! cannot create work folder in $OUT_DIR"; FAILED_REPOS+=("$owner/$repo"); return; }
  work="$CUR_WORK"
  dest="$work/$repo"; mkdir -p "$dest"
  MEASURE_PATH="$work"
  ui_refresh force

  # 1. Repo metadata (description, topics, settings, size estimate, etc.)
  STAGE="Reading repository metadata"; FRAC_PM=10; ui_refresh force
  if ! gh_request "$api" "$dest/repo.json"; then
    log "  ! repo metadata failed (HTTP $HTTP_CODE)"; API_FAIL=$((API_FAIL + 1)); echo '{}' > "$dest/repo.json"
  fi
  est_kb="$(jq -r '.size // 0' "$dest/repo.json" 2>/dev/null)"
  [[ "$est_kb" =~ ^[0-9]+$ ]] || est_kb=0

  # 2. Full git mirror: all branches, tags, and pull request refs
  est=$((est_kb * 1024)); [ "$est" -lt 1048576 ] && est=1048576
  STAGE="Cloning git mirror"
  DETAIL="repo size ~ $(human_bytes $((est_kb * 1024)))"
  FRAC_PM=30; ui_refresh force
  env "${GIT_ENV[@]}" git clone --mirror --quiet \
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
  api_get_all "$api/issues" "state=all" "$TMP/issues_all.json"
  jq 'map(select(has("pull_request") | not))' "$TMP/issues_all.json" > "$dest/issues/issues.json"
  ISSUES="$(jq length "$dest/issues/issues.json")"
  log "  issues: $ISSUES"

  # One repo-wide request stream returns the conversation comments of ALL issues and
  # PRs (far fewer API calls than asking per item); they are sorted into files below.
  DETAIL="issue + PR conversation comments"; FRAC_PM=760; ui_refresh force
  api_get_all "$api/issues/comments" "" "$TMP/conv_all.json"

  # 4. Pull requests. (The PR *list* carries no comment counts, so nothing can be
  #    skipped based on it; every PR is queried for its reviews.)
  STAGE="Fetching pull requests"; DETAIL="pull request list"; FRAC_PM=820; ui_refresh force
  mkdir -p "$dest/pulls/conversation" "$dest/pulls/review-comments" "$dest/pulls/reviews"
  api_get_all "$api/pulls" "state=all" "$dest/pulls/pulls.json"
  PRS="$(jq length "$dest/pulls/pulls.json")"
  jq -r '.[].number' "$dest/pulls/pulls.json" > "$TMP/prnums"

  DETAIL="review comments"; FRAC_PM=850; ui_refresh force
  api_get_all "$api/pulls/comments" "" "$TMP/rc_all.json"
  split_by_number "$TMP/rc_all.json" pull_request_url "$dest/pulls/review-comments"

  # sort the conversation comments: PR number -> pulls/conversation, otherwise issues/comments
  rm -rf "$TMP/conv"; split_by_number "$TMP/conv_all.json" issue_url "$TMP/conv"
  for f in "$TMP/conv"/*.json; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.json}"
    if grep -qxF "$n" "$TMP/prnums"; then mv -f "$f" "$dest/pulls/conversation/$n.json"
    else mv -f "$f" "$dest/issues/comments/$n.json"; fi
  done
  rm -f "$TMP/issues_all.json" "$TMP/conv_all.json" "$TMP/rc_all.json"

  mapfile -t pnums < "$TMP/prnums"
  total=${#pnums[@]}; i=0
  for n in ${pnums[@]+"${pnums[@]}"}; do
    i=$((i+1)); DETAIL="reviews of PR #$n  ($i/$total)"
    FRAC_PM=$(( 870 + 100 * i / total )); ui_refresh
    api_get_all "$api/pulls/$n/reviews" "" "$dest/pulls/reviews/$n.json"
    # drop empty files to keep the archive tidy
    [ "$(jq length "$dest/pulls/reviews/$n.json" 2>/dev/null)" = "0" ] && rm -f "$dest/pulls/reviews/$n.json"
  done
  log "  pull requests: $PRS"

  # small manifest inside the archive
  jq -n --arg repo "$owner/$repo" --arg when "$(date -Is)" \
        --argjson issues "${ISSUES//[^0-9]/0}" --argjson prs "${PRS//[^0-9]/0}" --argjson errors "$API_FAIL" \
    '{repository:$repo, backed_up_at:$when, issues:$issues, pull_requests:$prs, api_errors:$errors,
      note:"api_errors > 0 means some issue/PR data could not be fetched"}' > "$dest/backup-info.json"

  # 5. Zip into Downloads with a timestamp name
  DETAIL=""; STAGE="Compressing to zip"; FRAC_PM=970; ui_refresh force
  MEASURE_PATH=""          # stop measuring (no network traffic while zipping)
  ts="$(date +"%Y.%m.%d.%H.%M.%S")"
  out="$OUT_DIR/$ts - $repo.zip"; CUR_OUT="$out"
  make_zip "$work" "$repo" "$out" "$dest/git-mirror.git" 970 28; rc=$?
  if [ "$rc" -eq 0 ]; then
    log "  saved: $out  ($(human_bytes "$(stat -c%s "$out")"))"
    SAVED+=("$out"); DONE_REPOS+=("$repo")
    if [ "$API_FAIL" -gt 0 ]; then
      log "  ! saved with $API_FAIL API problem(s) - some issue/PR data is missing"
      WARN_REPOS+=("$owner/$repo")
    fi
  else
    log "  ! zip failed: $(tail -n 2 "$TMP/zip.err" 2>/dev/null | tr '\n' ' ')${ZIP_LOST:+ - files that vanished while zipping: $ZIP_LOST}"; rm -f "$out"; FAILED_REPOS+=("$owner/$repo")
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
finish_ui "Finished!"$'\n'"${#DONE_REPOS[@]} of $N repo(s) saved in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Failed: ${#FAILED_REPOS[@]}   With warnings: ${#WARN_REPOS[@]}"$'\n'"Saved in: $OUT_DIR"
echo "Done."
command -v notify-send >/dev/null && notify-send "Repo backup finished" "${#DONE_REPOS[@]} of $N repo(s) saved to $OUT_DIR (${#FAILED_REPOS[@]} failed, ${#WARN_REPOS[@]} with warnings)"
exit $(( ${#FAILED_REPOS[@]} + ${#WARN_REPOS[@]} > 0 ? 1 : 0 ))

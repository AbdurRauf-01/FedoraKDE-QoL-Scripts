#!/usr/bin/env bash
# Downloads selected assets of each chosen repo's latest release into
# ~/Downloads/"<release name>"/
#  - Opens its own console window when started from a launcher / file manager.
#  - A selection dialog opens on launch; all repos are ticked by default.
#  - A GUI progress window shows the current repo + file, speed, ETA and
#    the repos that are already finished. Press Cancel in it (or Ctrl+C) to stop.
#  - Downloads are checked against GitHub's sha256 digest when it provides one,
#    and unfinished downloads (*.part) are resumed on the next run.
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

# Only assets whose file name ENDS with one of these are downloaded
# (case-insensitive). Leave the list empty to download every asset.
# Add more lines to also grab e.g. "SHA256SUMS.txt".
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

# Seconds the final "Finished" text stays in the progress window.
FINISH_LINGER=3

TOKEN_FILE="$HOME/.config/github-token"

OUT_DIR="$HOME/Downloads"

REQUIRED_CMDS=(curl jq awk stat base64)

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

# ===========================================================================
# Latest release download
# ===========================================================================
N=0; CURL_PID=""; CUR_PART=""
TOTAL_BYTES=0; TOTAL_FILES=0; DONE_BYTES=0; FILES_OK=0; FILES_SKIPPED=0; FILES_FAILED=0
DONE_REPOS=(); SKIPPED_REPOS=(); FAILED_ITEMS=(); FOLDERS=()
DL_START_US=0

# NOTE: an unfinished *.part file is deliberately kept on cancel / error / Ctrl+C;
# the next run resumes it (curl -C -).
on_cleanup() {
  [ -n "$CURL_PID" ] && kill "$CURL_PID" 2>/dev/null
}

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
    echo " Failed items (unfinished downloads resume on the next run):"
    for f in "${FAILED_ITEMS[@]}"; do echo "   $f"; done
  fi
  if [ "$RATE_LIMITED" = 1 ]; then
    echo " The GitHub API rate limit was hit - set GITHUB_TOKEN (or ~/.config/github-token) and run again."
  fi
  echo "========================================="
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

# Checks a file against the digest GitHub reports for the asset ("sha256:<hex>").
# No digest (older releases) or no sha256sum -> nothing to check -> success.
verify_digest() {   # verify_digest <file> <digest-or-dash>
  case "$2" in
    sha256:*)
      command -v sha256sum >/dev/null || return 0
      [ "$(sha256sum "$1" | cut -d' ' -f1)" = "${2#sha256:}" ] ;;
    *) return 0 ;;
  esac
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
mkdir -p "$OUT_DIR"
progress_start "Download latest releases"

declare -a R_PATH R_SHORT R_REL R_FOLDER R_STATE R_COUNT R_ERR

# ---- Phase 1: look up every release first (so we know the total size) ----
echo "Checking latest releases ($N repos)..."
for ((i=0; i<N; i++)); do
  repo_parts "${SELECTED[i]}"; owner="$OWNER"; repo="$REPO"
  R_PATH[i]="$owner/$repo"; R_SHORT[i]="$repo"; R_REL[i]=""; R_FOLDER[i]=""
  R_STATE[i]="norelease"; R_COUNT[i]=0; R_ERR[i]=""

  progress_update 0 "Checking releases ($((i+1)) of $N)..."$'\n'"$owner/$repo" || cancel_exit

  # /releases/latest returns the newest published release (not drafts or pre-releases)
  if ! gh_request "https://api.github.com/repos/$owner/$repo/releases/latest" "$TMP/rel.json"; then
    if [ "$HTTP_CODE" = 404 ]; then
      log "  $owner/$repo: no published release"
    else
      R_STATE[i]="apierror"; R_ERR[i]="GitHub API error (HTTP $HTTP_CODE)"
      log "  ! $owner/$repo: ${R_ERR[i]}"
    fi
    continue
  fi
  json="$(cat "$TMP/rel.json")"

  name="$(jq -r '.name // empty' <<<"$json")"
  [ -z "$name" ] && name="$(jq -r '.tag_name' <<<"$json")"
  # named "<repo> - <release>" so two repos with the same release name never share a folder
  folder_name="$(sanitize "$repo - $name")"
  folder="$OUT_DIR/$folder_name"
  R_REL[i]="$name"; R_FOLDER[i]="$folder"

  total="$(jq '.assets | length' <<<"$json")"
  if [ "$total" -eq 0 ]; then
    R_STATE[i]="noassets"; log "  $owner/$repo: release '$name' has no attached files"; continue
  fi

  : > "$TMP/$i.assets"
  nm=0
  while IFS=$'\t' read -r file dl size digest; do
    want_asset "$file" || continue
    printf '%s\t%s\t%s\t%s\n' "$file" "$dl" "$size" "$digest" >> "$TMP/$i.assets"
    nm=$((nm+1))
    # already fully downloaded? then it does not count towards the total
    if [ -f "$folder/$file" ] && [ "$(stat -c%s "$folder/$file")" = "$size" ]; then continue; fi
    TOTAL_BYTES=$((TOTAL_BYTES + size)); TOTAL_FILES=$((TOTAL_FILES + 1))
  done < <(jq -r '.assets[] | [.name, .browser_download_url, (.size|tostring), (.digest // "-")] | @tsv' <<<"$json")

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
    norelease) log "  no published release";                        SKIPPED_REPOS+=("$repo"); continue ;;
    apierror)  log "  ! ${R_ERR[i]}"; FAILED_ITEMS+=("$repo: ${R_ERR[i]}"); continue ;;
    noassets)  log "  no attached files in this release";           SKIPPED_REPOS+=("$repo"); continue ;;
    nomatch)   log "  none of the assets matched ASSET_SUFFIXES";   SKIPPED_REPOS+=("$repo"); continue ;;
  esac
  echo "  release: $rel_name"

  fcount="${R_COUNT[i]}"; fidx=0; repo_failed=0
  while IFS=$'\t' read -r -u 4 file dl size digest; do
    fidx=$((fidx+1))
    mkdir -p "$folder"
    if [ -f "$folder/$file" ] && [ "$(stat -c%s "$folder/$file")" = "$size" ]; then
      log "  already exists, skipping: $file"; FILES_SKIPPED=$((FILES_SKIPPED+1)); continue
    fi

    # resume an earlier unfinished download if there is one
    CUR_PART="$folder/$file.part"; ps=0
    [ -f "$CUR_PART" ] && ps="$(stat -c%s "$CUR_PART")"
    if [ "$ps" -gt "$size" ]; then rm -f "$CUR_PART"; ps=0; fi
    if [ "$ps" -gt 0 ]; then log "  downloading: $file ($(human_bytes "$size"), resuming at $(human_bytes "$ps"))"
    else log "  downloading: $file ($(human_bytes "$size"))"; fi

    rc=0; sz="$ps"; spd=0
    if [ "$ps" -lt "$size" ] || [ ! -f "$CUR_PART" ]; then
      curl -fL -sS ${AUTH[@]+"${AUTH[@]}"} -C - -o "$CUR_PART" "$dl" 2>"$TMP/curl.err" &
      CURL_PID=$!
      last_sz=$ps; last_t=${EPOCHREALTIME/[.,]/}; file_t0=$last_t
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
    fi

    fail_msg=""
    if [ "$rc" -ne 0 ] || [ ! -f "$CUR_PART" ]; then
      fail_msg="download error $(head -c 200 "$TMP/curl.err" 2>/dev/null)"        # .part kept for resuming
    elif [ "$(stat -c%s "$CUR_PART")" != "$size" ]; then
      fail_msg="size mismatch (got $(stat -c%s "$CUR_PART"), expected $size)"; rm -f "$CUR_PART"
    elif ! verify_digest "$CUR_PART" "$digest"; then
      fail_msg="checksum mismatch (does not match GitHub's ${digest%%:*} digest)"; rm -f "$CUR_PART"
    fi

    if [ -z "$fail_msg" ]; then
      mv -f "$CUR_PART" "$folder/$file"; CUR_PART=""
      sz="$size"
      secs=$(( ( ${EPOCHREALTIME/[.,]/} - ${file_t0:-${EPOCHREALTIME/[.,]/}} ) / 1000000 )); [ "$secs" -lt 1 ] && secs=1
      release_ui                      # show 100% for this file ...
      DONE_BYTES=$((DONE_BYTES + size)); FILES_OK=$((FILES_OK+1))   # ... then count it as done
      case "$digest" in sha256:*) vtxt=", sha256 verified" ;; *) vtxt="" ;; esac
      log "  done: $file  (avg $(human_bytes $(( (size-ps)/secs )))/s$vtxt)"
    else
      CUR_PART=""
      log "  ! failed: $file  $fail_msg"
      FILES_FAILED=$((FILES_FAILED+1)); repo_failed=1
      FAILED_ITEMS+=("$repo: $file - $fail_msg")
    fi
  done 4< "$TMP/$i.assets"

  FOLDERS+=("$folder")
  [ "$repo_failed" -eq 0 ] && DONE_REPOS+=("$repo")
  echo "  matched $fcount file(s) -> $folder"
done

# ---- Finish ----
summary
finish_ui "Finished!"$'\n'"Downloaded $FILES_OK file(s), $(human_bytes "$DONE_BYTES") in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Failed: ${#FAILED_ITEMS[@]}"$'\n'"Saved in: $OUT_DIR"
echo "Done."
command -v notify-send >/dev/null && notify-send "Release download finished" "$FILES_OK file(s), $(human_bytes "$DONE_BYTES") - $N repo(s) processed, ${#FAILED_ITEMS[@]} failed"
exit $(( ${#FAILED_ITEMS[@]} > 0 ? 1 : 0 ))

#!/usr/bin/env bash
# repo-tool.sh - download GitHub repositories in four ways, from one menu.
#
# Presets (menu entries, or --preset NAME):
#   backup       Full backup: git mirror (all branches, tags, PR refs) + issues +
#                pull requests + every comment and review -> one archive per repo.
#   code         Code only: plain "git clone" (files, all branches, all tags) ->
#                one archive per repo. No GitHub API calls, so no rate limit.
#   release-all  Latest release files whose names match ASSET_SUFFIXES, all repos
#                ticked by default.
#   release      Same, with no repos ticked by default.
#
# Repository list: ~/.config/repo-tool/repos.txt. Add, remove, view or restore it
# from the menu; nothing in this script needs editing to change the repos.
#
# Archives are ZIP or RAR (20% recovery record, normal compression); switch in the menu
# ("Archive format") or per run with --format. RAR needs the "rar" command.
# Output goes to ~/Downloads. A GUI (zenity or kdialog) is used when available,
# otherwise everything works in the console.
#  - Opens its own console window when started from a launcher / file manager.

set -u

# ===========================================================================
# Re-open in a terminal if started without one (double-click / launcher)
# ===========================================================================
if [ ! -t 1 ] && [ -z "${REPO_TOOL_IN_TERM:-}" ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  export REPO_TOOL_IN_TERM=1
  _self="$(readlink -f "${BASH_SOURCE[0]}")"
  _wrap='bash "$@"; rc=$?; echo; read -r -p "Finished (exit code $rc). Press Enter to close this window... " _'
  for _t in konsole ptyxis gnome-terminal xfce4-terminal mate-terminal alacritty kitty foot xterm; do
    command -v "$_t" >/dev/null 2>&1 || continue
    case "$_t" in
      gnome-terminal|ptyxis)        exec "$_t" -- bash -c "$_wrap" _ "$_self" "$@" ;;
      xfce4-terminal|mate-terminal) exec "$_t" -x bash -c "$_wrap" _ "$_self" "$@" ;;
      kitty|foot)                   exec "$_t" bash -c "$_wrap" _ "$_self" "$@" ;;
      *)                            exec "$_t" -e bash -c "$_wrap" _ "$_self" "$@" ;;
    esac
  done
fi

# ===========================================================================
# Command line
# ===========================================================================
OPT_ALL=0; OPT_NOGUI=0; HAVE_PRESET=0; CLI_PRESET=""; CLI_FORMAT=""

usage() {
  cat <<EOF
Usage: ${0##*/} [--preset NAME] [--format zip|rar] [--all] [--no-gui]
  --preset NAME  run one preset straight away: backup | code | release-all | release
  --format F     archive format for backup / code: zip or rar (this run only; the menu
                 entry "Archive format" changes the saved default)
  --all          no selection dialog: process every repository in the list
  --no-gui       console only (no dialogs, no progress window)
  --help         show this text
Without --preset a menu opens: run a preset, or add / remove / view repositories.
GitHub token: GITHUB_TOKEN, or the first line of ~/.config/github-token.
It is needed for private repositories and avoids the 60-requests-per-hour limit.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --preset)   HAVE_PRESET=1; CLI_PRESET="${2:-}"; shift ;;
    --preset=*) HAVE_PRESET=1; CLI_PRESET="${1#*=}" ;;
    --format)   CLI_FORMAT="${2:-}"; shift ;;
    --format=*) CLI_FORMAT="${1#*=}" ;;
    --all)      OPT_ALL=1 ;;
    --no-gui)   OPT_NOGUI=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
case "$CLI_FORMAT" in
  ''|zip|rar) ;;
  *) echo "Unknown format: '$CLI_FORMAT' (use zip or rar)" >&2; exit 2 ;;
esac

# ===========================================================================
# Settings
# ===========================================================================
OUT_DIR="$HOME/Downloads"
CONFIG_DIR="$HOME/.config/repo-tool"
REPO_LIST="$CONFIG_DIR/repos.txt"
TOKEN_FILE="$HOME/.config/github-token"

# Release presets: only assets whose file name ENDS with one of these are downloaded
# (case-insensitive). An empty list downloads every asset.
ASSET_SUFFIXES=(
  "-linux-x86_64.flatpak"
  "-windows-x64.msi"
  "-linux-x86_64.flatpak.asc"
  "-windows-x64.msi.asc"
)

# Code preset: normal = working copy (default branch's files, plus all branches and tags)
#              bare   = repository data only (smaller archive; restore with: git clone proj.git proj)
CLONE_MODE="normal"

# Archive format for the backup and code presets: zip or rar.
# The menu entry "Archive format" changes it and remembers the choice; --format overrides it for one run.
# RAR needs the proprietary "rar" command (unrar can only extract).
# RAR_LEVEL: 3 = normal compression.  RAR_RECOVERY: size of the recovery record in percent.
ARCHIVE_FORMAT="zip"
RAR_LEVEL=3
RAR_RECOVERY=20
FORMAT_FILE="$CONFIG_DIR/format"

# Selection dialog size, and which dialog tool to use (auto = zenity if installed, else kdialog)
DIALOG_TOOL="auto"
DIALOG_WIDTH=900
DIALOG_HEIGHT=800
FINISH_LINGER=3          # seconds the "Finished" text stays in the progress window

# Built-in list. Used the first time the tool runs, and by "Restore built-in list".
DEFAULT_REPOS=(
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
)

REPOS=()
SELECTED=()
GUI_TOOL=""

# ===========================================================================
# Small helpers
# ===========================================================================
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

tail_list() {   # tail_list <array name> -> "a, b, c" (last 6 only)
  local -n _arr=$1
  local n=${#_arr[@]} max=6 start=0 i out=""
  [ "$n" -eq 0 ] && { printf 'none yet'; return; }
  [ "$n" -gt "$max" ] && start=$((n-max))
  for ((i=start; i<n; i++)); do out+="${_arr[i]}, "; done
  out="${out%, }"
  [ "$start" -gt 0 ] && out="... +$start earlier, $out"
  printf '%s' "$out"
}

join_words() {   # join_words a b c -> "a, b, c" or "none"
  local out="" x
  for x in "$@"; do out+="${out:+, }$x"; done
  printf '%s' "${out:-none}"
}

repo_parts() {   # repo_parts <url> -> sets OWNER and REPO
  local p="$1"
  p="${p#https://github.com/}"; p="${p%/}"; p="${p%.git}"
  OWNER="${p%%/*}"; REPO="${p#*/}"
}

# Accepts https://github.com/o/r (also http, www., .git, trailing /), github.com/o/r,
# git@github.com:o/r.git or plain o/r. Prints the normalized URL, or returns 1.
normalize_repo() {
  local s="$1"
  s="${s//[[:space:]]/}"
  s="${s#https://}"; s="${s#http://}"; s="${s#www.}"
  s="${s#github.com/}"; s="${s#git@github.com:}"
  s="${s%/}"; s="${s%.git}"; s="${s%/}"
  [[ "$s" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf 'https://github.com/%s\n' "$s"
}

# contains <value> <array name>
contains() {
  local -n _c=$2
  local x
  for x in "${_c[@]}"; do [ "$x" = "$1" ] && return 0; done
  return 1
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

# Checks a file against GitHub's digest for the asset ("sha256:<hex>").
# No digest (older releases) or no sha256sum -> nothing to check -> success.
verify_digest() {   # verify_digest <file> <digest or ->
  case "$2" in
    sha256:*)
      command -v sha256sum >/dev/null || return 0
      [ "$(sha256sum "$1" | cut -d' ' -f1)" = "${2#sha256:}" ] ;;
    *) return 0 ;;
  esac
}

# ===========================================================================
# Repository list (repos.txt): load, save, add, remove, view, restore
# ===========================================================================
save_repos() {
  mkdir -p "$CONFIG_DIR"
  {
    echo "# GitHub repositories for repo-tool.sh - one per line. Lines starting with # are ignored."
    printf '%s\n' "${REPOS[@]}"
  } > "$REPO_LIST.tmp" && mv -f "$REPO_LIST.tmp" "$REPO_LIST"
}

load_repos() {
  REPOS=()
  if [ ! -f "$REPO_LIST" ]; then
    REPOS=("${DEFAULT_REPOS[@]}")
    save_repos
  fi
  local line url
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -z "$line" ] && continue
    if ! url="$(normalize_repo "$line")"; then
      echo "repo-tool: ignoring invalid line in $REPO_LIST: $line" >&2; continue
    fi
    contains "$url" REPOS && continue
    REPOS+=("$url")
  done < "$REPO_LIST"
}

add_repos_flow() {
  local input tok url added=() bad=() dup=() toks=() msg
  input="$(ui_entry "Add repositories" "Paste GitHub links or owner/repo names. Separate several with spaces or commas.")" || return 0
  [ -z "${input//[[:space:]]/}" ] && return 0
  read -ra toks <<<"${input//,/ }"
  for tok in "${toks[@]}"; do
    if ! url="$(normalize_repo "$tok")"; then bad+=("$tok"); continue; fi
    if contains "$url" REPOS; then dup+=("${url#https://github.com/}"); continue; fi
    REPOS+=("$url"); added+=("${url#https://github.com/}")
  done
  [ "${#added[@]}" -gt 0 ] && save_repos
  msg="Added (${#added[@]}): $(join_words "${added[@]+"${added[@]}"}")"
  msg+=$'\n'"Already in the list (${#dup[@]}): $(join_words "${dup[@]+"${dup[@]}"}")"
  msg+=$'\n'"Not understood (${#bad[@]}): $(join_words "${bad[@]+"${bad[@]}"}")"
  msg+=$'\n\n'"Now ${#REPOS[@]} repositories in the list."
  ui_info "Add repositories" "$msg"
}

remove_repos_flow() {
  local u old=() removed=()
  if [ "${#REPOS[@]}" -eq 0 ]; then ui_info "Remove repositories" "The list is empty."; return 0; fi
  choose_repos "Remove repositories" "Tick the repositories to REMOVE from the list. Nothing is deleted from your disk." FALSE 0 \
    || return 0
  ui_yesno "Remove repositories" "Remove ${#SELECTED[@]} repositor$([ "${#SELECTED[@]}" -eq 1 ] && echo y || echo ies) from the list?" || return 0
  old=("${REPOS[@]}"); REPOS=()
  for u in "${old[@]}"; do
    if contains "$u" SELECTED; then removed+=("${u#https://github.com/}"); else REPOS+=("$u"); fi
  done
  save_repos
  ui_info "Remove repositories" "Removed (${#removed[@]}): $(join_words "${removed[@]}")"$'\n\n'"Now ${#REPOS[@]} repositories in the list."
}

view_repos() {
  local i text=""
  for i in "${!REPOS[@]}"; do text+="$(printf '%3d) %s' "$((i+1))" "${REPOS[i]#https://github.com/}")"$'\n'; done
  [ -z "$text" ] && text="(the list is empty)"$'\n'
  ui_text "Repository list (${#REPOS[@]})" "$text"
}

reset_repos() {
  ui_yesno "Restore built-in list" "Replace the current list with the ${#DEFAULT_REPOS[@]} built-in repositories? Repositories you added will be removed from the list." || return 0
  REPOS=("${DEFAULT_REPOS[@]}")
  save_repos
  ui_info "Restore built-in list" "The list now holds the ${#REPOS[@]} built-in repositories."
}

# ===========================================================================
# Archive format (zip / rar)
# ===========================================================================
ARCHIVE_EXT=zip; ARCH_CMD=zip

set_format_vars() {
  case "$ARCHIVE_FORMAT" in
    rar) ARCHIVE_EXT=rar; ARCH_CMD=rar ;;
    *)   ARCHIVE_FORMAT=zip; ARCHIVE_EXT=zip; ARCH_CMD=zip ;;
  esac
}

load_format() {
  local f
  if [ -n "$CLI_FORMAT" ]; then
    ARCHIVE_FORMAT="$CLI_FORMAT"
  elif [ -f "$FORMAT_FILE" ]; then
    f="$(head -n 1 "$FORMAT_FILE" | tr -d '[:space:]')"
    case "$f" in zip|rar) ARCHIVE_FORMAT="$f" ;; esac
  fi
  set_format_vars
}

RAR_HINT="RAR is proprietary software, so the 'rar' command has to be installed separately:
  Fedora:         sudo dnf install rar     (needs the RPM Fusion nonfree repository)
  Debian/Ubuntu:  sudo apt install rar
  or download it from https://www.rarlab.com/download.htm"

toggle_format_flow() {
  local new
  if [ "$ARCHIVE_FORMAT" = zip ]; then new=rar; else new=zip; fi
  if [ "$new" = rar ] && ! command -v rar >/dev/null; then
    ui_info "Archive format" "Cannot switch to RAR: the 'rar' command was not found."$'\n\n'"$RAR_HINT"
    return 0
  fi
  ARCHIVE_FORMAT="$new"; set_format_vars
  mkdir -p "$CONFIG_DIR"; printf '%s\n' "$new" > "$FORMAT_FILE"
  if [ "$new" = rar ]; then
    ui_info "Archive format" "Backups and code downloads are now saved as RAR archives (.rar) with a ${RAR_RECOVERY}% recovery record and normal compression."
  else
    ui_info "Archive format" "Backups and code downloads are now saved as ZIP archives (.zip)."
  fi
}

# ===========================================================================
# User interface: GUI (zenity / kdialog) with a console fallback for everything
# ===========================================================================
detect_gui() {
  GUI_TOOL=""
  [ "$OPT_NOGUI" = 1 ] && return 0
  [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && return 0
  case "$DIALOG_TOOL" in
    zenity)  command -v zenity  >/dev/null && GUI_TOOL=zenity ;;
    kdialog) command -v kdialog >/dev/null && GUI_TOOL=kdialog ;;
    *)       if   command -v zenity  >/dev/null; then GUI_TOOL=zenity
             elif command -v kdialog >/dev/null; then GUI_TOOL=kdialog; fi ;;
  esac
}

# ui_menu <title> <text> id label [id label ...]  -> prints the chosen id; returns 1 on cancel
ui_menu() {
  local title="$1" text="$2" i choice a
  shift 2
  local ids=() labels=()
  while [ $# -ge 2 ]; do ids+=("$1"); labels+=("$2"); shift 2; done
  if [ -n "$GUI_TOOL" ]; then
    if [ "$GUI_TOOL" = zenity ]; then
      local rows=()
      for i in "${!ids[@]}"; do rows+=("${ids[i]}" "${labels[i]}"); done
      zenity --list --title="$title" --text="$text" --column=ID --column=Action \
        --hide-column=1 --print-column=1 --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" "${rows[@]}"
    else
      local args=()
      for i in "${!ids[@]}"; do args+=("${ids[i]}" "${labels[i]}"); done
      kdialog --title "$title" --menu "$text" "${args[@]}"
    fi
    return
  fi
  # console menu: everything shown goes to stderr, because stdout carries the answer
  { echo; echo "== $title =="; [ -n "$text" ] && echo "$text"
    for i in "${!ids[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${labels[i]}"; done; } >&2
  while :; do
    read -r -p "Choose a number: " a || return 1
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#ids[@]}" ]; then
      choice="${ids[a-1]}"; printf '%s\n' "$choice"; return 0
    fi
    echo "  please enter a number from 1 to ${#ids[@]}" >&2
  done
}

ui_info() {   # ui_info <title> <text>
  if   [ "$GUI_TOOL" = zenity ];  then zenity --info --title="$1" --text="$2" --width=520 2>/dev/null
  elif [ "$GUI_TOOL" = kdialog ]; then kdialog --title "$1" --msgbox "$2"
  else echo; echo "== $1 =="; echo "$2"; fi
}

ui_text() {   # ui_text <title> <text>
  if [ -n "$GUI_TOOL" ]; then
    local f; f="$(mktemp)"; printf '%s' "$2" > "$f"
    if [ "$GUI_TOOL" = zenity ]; then zenity --text-info --title="$1" --filename="$f" --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" 2>/dev/null
    else kdialog --title "$1" --textbox "$f" "$DIALOG_WIDTH" "$DIALOG_HEIGHT"; fi
    rm -f "$f"
  else
    echo; echo "== $1 =="; printf '%s' "$2"
  fi
}

ui_entry() {   # ui_entry <title> <text> -> prints the text typed; returns 1 on cancel
  if   [ "$GUI_TOOL" = zenity ];  then zenity --entry --title="$1" --text="$2" --width=560 2>/dev/null
  elif [ "$GUI_TOOL" = kdialog ]; then kdialog --title "$1" --inputbox "$2"
  else
    local v
    { echo; echo "$2"; } >&2
    read -r -p "> " v || return 1
    printf '%s\n' "$v"
  fi
}

ui_yesno() {   # ui_yesno <title> <question>  -> returns 0 for yes
  if   [ "$GUI_TOOL" = zenity ];  then zenity --question --title="$1" --text="$2" --width=460 2>/dev/null
  elif [ "$GUI_TOOL" = kdialog ]; then kdialog --title "$1" --yesno "$2"
  else
    local a
    read -r -p "$2 [y/N] " a || return 1
    [[ "$a" =~ ^[Yy] ]]
  fi
}

# choose_repos <title> <text> <TRUE|FALSE default> <allow --all: 1|0>
# Fills SELECTED. Returns 1 if cancelled or nothing was picked.
choose_repos() {
  local title="$1" text="$2" def="$3" allow_all="$4" u out rows=() geo=() tok lo hi k a def_word
  SELECTED=()
  if [ "$OPT_ALL" = 1 ] && [ "$allow_all" = 1 ]; then SELECTED=("${REPOS[@]}"); return 0; fi
  if [ "${#REPOS[@]}" -eq 0 ]; then ui_info "$title" "The repository list is empty. Add repositories first."; return 1; fi

  if [ "$GUI_TOOL" = zenity ]; then
    for u in "${REPOS[@]}"; do rows+=("$def" "${u#https://github.com/}" "$u"); done
    out="$(zenity --list --checklist --title="$title" --text="$text" \
      --column=Pick --column=Repository --column=URL --hide-column=3 --print-column=3 \
      --separator=$'\n' --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" "${rows[@]}" 2>/dev/null)" || return 1
  elif [ "$GUI_TOOL" = kdialog ]; then
    # --geometry is honoured on X11 only; only pass it if this kdialog build knows the option
    if kdialog --help-all 2>&1 | grep -q -- '--geometry'; then geo=(--geometry "${DIALOG_WIDTH}x${DIALOG_HEIGHT}"); fi
    local state="off"; [ "$def" = TRUE ] && state="on"
    for u in "${REPOS[@]}"; do rows+=("$u" "${u#https://github.com/}" "$state"); done
    out="$(kdialog ${geo[@]+"${geo[@]}"} --title "$title" --separate-output \
      --checklist "$text" "${rows[@]}")" || return 1
  else
    def_word=none; [ "$def" = TRUE ] && def_word=all
    echo; echo "== $title =="; [ -n "$text" ] && echo "$text"
    for k in "${!REPOS[@]}"; do printf '  %3d) %s\n' "$((k+1))" "${REPOS[k]#https://github.com/}"; done
    read -r -p "Numbers (e.g. 1,4,7-9), 'all' or 'none' [$def_word]: " a || a=""
    a="${a:-$def_word}"
    case "$a" in
      all)  SELECTED=("${REPOS[@]}") ;;
      none) ;;
      *)
        for tok in ${a//,/ }; do
          if [[ "$tok" =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
            lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[3]:-$lo}
            for ((k=lo; k<=hi; k++)); do
              [ "$k" -ge 1 ] && [ "$k" -le "${#REPOS[@]}" ] && SELECTED+=("${REPOS[k-1]}")
            done
          else
            echo "  ignored: $tok"
          fi
        done ;;
    esac
    out=""
  fi
  [ -n "${out:-}" ] && mapfile -t SELECTED <<<"$out"

  # de-duplicate (a repo picked twice must not be processed twice)
  local -A seen=(); local -a uniq=()
  for u in "${SELECTED[@]}"; do
    [ -n "${u}" ] && [ -z "${seen[$u]:-}" ] && { seen[$u]=1; uniq+=("$u"); }
  done
  SELECTED=("${uniq[@]+"${uniq[@]}"}")
  [ "${#SELECTED[@]}" -gt 0 ]
}

# ===========================================================================
# Run setup (per run, inside a subshell so the menu survives a finished/cancelled run)
# ===========================================================================
TMP=""; CHILD_PID=""; CURL_PID=""; RUN_START=$SECONDS
PROG_ON=0; ZPID=""; ZFIFO=""; QDBUS=""; KD_SVC=""; KD_PATH=""
AUTH=(); GIT_ENV=(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false)
RATE_LIMITED=0; HTTP_CODE=000

on_cleanup() { :; }      # each preset replaces this with its own temp-file cleanup

cleanup() {
  trap - EXIT
  if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; fi
  if [ -n "$CURL_PID" ];  then kill "$CURL_PID"  2>/dev/null; fi
  on_cleanup
  progress_stop
  [ -n "$TMP" ] && rm -rf "$TMP"
}

init_run() {   # init_run "<required commands>"
  local cmd token
  for cmd in $1; do
    if ! command -v "$cmd" >/dev/null; then
      if [ "$cmd" = rar ]; then
        echo "Missing dependency: rar"; echo "$RAR_HINT"; echo "Or use ZIP instead: --format zip (or the menu entry \"Archive format\")."
      else
        echo "Missing dependency: $cmd  (install it, e.g. sudo dnf install $cmd)"
      fi
      exit 1
    fi
  done
  TMP="$(mktemp -d)" || exit 1

  token="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"
  token="${token//[[:space:]]/}"
  if [ -n "$token" ]; then
    # kept out of process arguments: curl reads it from a file, git gets it via environment
    printf 'Authorization: Bearer %s\n' "$token" > "$TMP/auth.hdr"
    AUTH=(-H "@$TMP/auth.hdr")
    GIT_ENV+=(GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=http.extraheader
              "GIT_CONFIG_VALUE_2=Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 -w0)")
  else
    echo "Note: no GitHub token (GITHUB_TOKEN or $TOKEN_FILE)."
    echo "      The API allows 60 requests/hour and private repositories are not reachable."
  fi
  unset token

  trap '' PIPE
  trap cleanup EXIT
  trap 'echo; echo "Interrupted."; exit 130' INT TERM HUP
}

cancel_exit() {
  echo; echo "Cancelled."
  summary
  exit 130
}

# ---------------------------------------------------------------------------
# Archive a work folder as ZIP or RAR (ARCHIVE_FORMAT).
# Right after a clone / fetch git can still be tidying up inside .git (lock files,
# temporary packs, automatic maintenance). If a file disappears while the archiver is
# reading the folder it stops with "No such file or directory". So:
#   - git's automatic maintenance is switched off for our git commands (see GIT_ENV),
#   - we wait until no lock file or temporary pack is left in the git folder,
#   - and if files still vanish, archiving is retried (3 attempts), naming the vanished files.
# Symlinks are stored as links (zip -y, rar -ol) instead of being followed.
# ZIP: zip -qry.   RAR: rar a -m<RAR_LEVEL> -rr<RAR_RECOVERY>% (normal compression, recovery record).
# make_archive <work-dir> <entry> <output-file> <git-dir> <progress-base-permille> <progress-span-permille>
# Returns 0 on success; ARCH_LOST holds the first vanished files if it kept failing.
# ---------------------------------------------------------------------------
ARCH_LOST=""

wait_git_quiet() {   # wait up to 30 s until the git folder holds no lock file / temporary pack
  local d="$1" i
  [ -d "$d" ] || return 0
  for i in $(seq 1 30); do
    [ -z "$(find "$d" \( -name '*.lock' -o -name 'gc.pid' -o -name 'tmp_*' \) -print -quit 2>/dev/null)" ] && return 0
    sleep 1
  done
  return 0
}

make_archive() {
  local work="$1" entry="$2" out="$3" gitdir="$4" base="$5" span="$6" attempt rc zpid zt
  ARCH_LOST=""
  for attempt in 1 2 3; do
    wait_git_quiet "$gitdir"
    find "$work/$entry" -mindepth 1 2>/dev/null | sort > "$TMP/arch.before"
    rm -f "$out"
    if [ "$ARCHIVE_FORMAT" = rar ]; then
      ( cd "$work" && exec rar a -idq -y -r -ol -ma5 -m"$RAR_LEVEL" -rr"$RAR_RECOVERY"% "$out" "$entry" >"$TMP/arch.err" 2>&1 ) &
    else
      ( cd "$work" && exec zip -qry "$out" "$entry" 2>"$TMP/arch.err" ) &
    fi
    zpid=$!; CHILD_PID=$zpid; zt=0
    while kill -0 "$zpid" 2>/dev/null; do
      zt=$((zt+1)); FRAC_PM=$(( base + span - span * 20 / (20 + zt) ))
      ui_refresh
      sleep 0.5
    done
    wait "$zpid"; rc=$?; CHILD_PID=""
    # integrity test of the finished archive
    if [ "$rc" -eq 0 ]; then
      if [ "$ARCHIVE_FORMAT" = rar ]; then
        rar t -idq "$out" >/dev/null 2>&1 || rc=1
      elif command -v unzip >/dev/null; then
        unzip -tqq "$out" >/dev/null 2>&1 || rc=1
      fi
    fi
    [ "$rc" -eq 0 ] && return 0

    # which files were in the folder before archiving but are gone now?
    find "$work/$entry" -mindepth 1 2>/dev/null | sort > "$TMP/arch.after"
    ARCH_LOST="$(comm -23 "$TMP/arch.before" "$TMP/arch.after" | head -n 5 | sed "s|^$work/||" | tr '\n' ' ')"
    # zip exit 18 / rar exit 1 (warning) or 6 (open error): a file could not be read
    if { [ "$ARCHIVE_FORMAT" = zip ] && [ "$rc" -eq 18 ]; } || { [ "$ARCHIVE_FORMAT" = rar ] && { [ "$rc" -eq 1 ] || [ "$rc" -eq 6 ]; }; }; then
      if [ "$attempt" -lt 3 ]; then
        log "  ! could not read some files (exit $rc${ARCH_LOST:+, vanished: $ARCH_LOST}) - trying again ($((attempt+1)) of 3)"
        sleep 3; continue
      fi
    fi
    break
  done
  rm -f "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# GitHub API request with retries. gh_request <url> <output-file>
# Sets HTTP_CODE; returns 0 only for HTTP 200. Retries network errors and 5xx.
# ---------------------------------------------------------------------------
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
# Progress window (zenity or kdialog) with a console fallback
# ---------------------------------------------------------------------------
progress_start() {   # progress_start <title>
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

# progress_update <percent> <text>   -> returns 1 if the user cancelled / closed the window
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

# Leaves the final text in the progress window for a moment.
finish_ui() {   # finish_ui <text>
  [ "$PROG_ON" = 1 ] || return 0
  progress_update 100 "$1" >/dev/null
  sleep "$FINISH_LINGER"
}

# ===========================================================================
# PRESET: backup  (full backup: mirror + issues + PRs + all comments + reviews)
# ===========================================================================
preset_backup() {
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
      echo " Archives:"; for f in "${SAVED[@]}"; do echo "   $f"; done
    fi
    if [ "${#WARN_REPOS[@]}" -gt 0 ]; then
      echo " Saved, but some GitHub API data is missing:"; for f in "${WARN_REPOS[@]}"; do echo "   $f"; done
    fi
    if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
      echo " Failed:"; for f in "${FAILED_REPOS[@]}"; do echo "   $f"; done
    fi
    [ "$RATE_LIMITED" = 1 ] && echo " The GitHub API rate limit was hit - add a token and run again."
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
  # A 410 (feature switched off for the repo) is not an error.
  api_get_all() {   # api_get_all <url> <query> <outfile>
    local url="$1" extra="${2:-}" out="$3" page=1 n
    : > "$TMP/pages"
    if [ "$RATE_LIMITED" = 1 ]; then API_FAIL=$((API_FAIL + 1)); echo '[]' > "$out"; return 0; fi
    while :; do
      if ! gh_request "${url}?${extra:+$extra&}per_page=100&page=${page}" "$TMP/body"; then
        [ "$HTTP_CODE" = 410 ] && break
        if [ "$RATE_LIMITED" = 1 ]; then
          log "  ! GitHub API rate limit reached - the rest of this run lacks issue/PR data (use a token)"
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
  split_by_number() {   # split_by_number <merged json> <field> <outdir>
    local src="$1" field="$2" outdir="$3" n json
    mkdir -p "$outdir"
    jq -r --arg f "$field" \
      'group_by(.[$f] // "")[] | ((.[0][$f] // "" | split("/") | last) + "\t" + tojson)' "$src" |
    while IFS=$'\t' read -r n json; do
      [ -n "$n" ] && printf '%s\n' "$json" | jq . > "$outdir/$n.json"
    done
  }

  finish_repo() {
    PREV_BYTES=$((PREV_BYTES + CUR_BYTES)); CUR_BYTES=0; LAST_BYTES=0
    MEASURE_PATH=""; [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"; CUR_WORK=""
  }

  backup_repo() {
    local url="$1" api work dest ts out est_kb est f i n total rc zt gpid zpid
    local pnums=() conv_n
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

    # 1. Repo metadata (description, topics, settings, size estimate)
    STAGE="Reading repository metadata"; FRAC_PM=10; ui_refresh force
    if ! gh_request "$api" "$dest/repo.json"; then
      log "  ! repo metadata failed (HTTP $HTTP_CODE)"; API_FAIL=$((API_FAIL + 1)); echo '{}' > "$dest/repo.json"
    fi
    est_kb="$(jq -r '.size // 0' "$dest/repo.json" 2>/dev/null)"
    [[ "$est_kb" =~ ^[0-9]+$ ]] || est_kb=0

    # 2. Full git mirror: all branches, tags, and pull request refs
    est=$((est_kb * 1024)); [ "$est" -lt 1048576 ] && est=1048576
    STAGE="Cloning git mirror"; DETAIL="repo size ~ $(human_bytes $((est_kb * 1024)))"
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

    # 3. Issues (the issues endpoint also returns PRs, so those are filtered out)
    STAGE="Fetching issues"; DETAIL="issue list"; FRAC_PM=700; ui_refresh force
    mkdir -p "$dest/issues/comments"
    api_get_all "$api/issues" "state=all" "$TMP/issues_all.json"
    jq 'map(select(has("pull_request") | not))' "$TMP/issues_all.json" > "$dest/issues/issues.json"
    ISSUES="$(jq length "$dest/issues/issues.json")"
    log "  issues: $ISSUES"

    # Conversation comments of ALL issues and PRs come from one repo-wide stream
    # (far fewer requests than one request per item); they are sorted below.
    DETAIL="issue and PR conversation comments"; FRAC_PM=760; ui_refresh force
    api_get_all "$api/issues/comments" "" "$TMP/conv_all.json"

    # 4. Pull requests. The PR list has no comment counts, so every PR is checked.
    STAGE="Fetching pull requests"; DETAIL="pull request list"; FRAC_PM=820; ui_refresh force
    mkdir -p "$dest/pulls/conversation" "$dest/pulls/review-comments" "$dest/pulls/reviews"
    api_get_all "$api/pulls" "state=all" "$dest/pulls/pulls.json"
    PRS="$(jq length "$dest/pulls/pulls.json")"
    jq -r '.[].number' "$dest/pulls/pulls.json" > "$TMP/prnums"

    DETAIL="review comments"; FRAC_PM=850; ui_refresh force
    api_get_all "$api/pulls/comments" "" "$TMP/rc_all.json"
    split_by_number "$TMP/rc_all.json" pull_request_url "$dest/pulls/review-comments"

    # sort the conversation comments: numbers that are PRs -> pulls/conversation, the rest -> issues
    rm -rf "$TMP/conv"; split_by_number "$TMP/conv_all.json" issue_url "$TMP/conv"
    for f in "$TMP/conv"/*.json; do
      [ -e "$f" ] || continue
      conv_n="${f##*/}"; conv_n="${conv_n%.json}"
      if grep -qxF "$conv_n" "$TMP/prnums"; then mv -f "$f" "$dest/pulls/conversation/$conv_n.json"
      else mv -f "$f" "$dest/issues/comments/$conv_n.json"; fi
    done
    rm -f "$TMP/issues_all.json" "$TMP/conv_all.json" "$TMP/rc_all.json"

    mapfile -t pnums < "$TMP/prnums"
    total=${#pnums[@]}; i=0
    for n in ${pnums[@]+"${pnums[@]}"}; do
      i=$((i+1)); DETAIL="reviews of PR #$n  ($i/$total)"
      FRAC_PM=$(( 870 + 100 * i / total )); ui_refresh
      api_get_all "$api/pulls/$n/reviews" "" "$dest/pulls/reviews/$n.json"
      [ "$(jq length "$dest/pulls/reviews/$n.json" 2>/dev/null)" = "0" ] && rm -f "$dest/pulls/reviews/$n.json"
    done
    log "  pull requests: $PRS"

    jq -n --arg repo "$owner/$repo" --arg when "$(date -Is)" \
          --argjson issues "${ISSUES//[^0-9]/0}" --argjson prs "${PRS//[^0-9]/0}" --argjson errors "$API_FAIL" \
      '{repository:$repo, backed_up_at:$when, issues:$issues, pull_requests:$prs, api_errors:$errors,
        note:"api_errors > 0 means some issue/PR data could not be fetched"}' > "$dest/backup-info.json"

    # 5. Archive into Downloads with a timestamp name
    DETAIL=""; STAGE="Compressing to ${ARCHIVE_FORMAT^^}"; FRAC_PM=970; ui_refresh force
    MEASURE_PATH=""
    ts="$(date +"%Y.%m.%d.%H.%M.%S")"
    out="$OUT_DIR/$ts - $repo.$ARCHIVE_EXT"; CUR_OUT="$out"
    make_archive "$work" "$repo" "$out" "$dest/git-mirror.git" 970 28; rc=$?
    if [ "$rc" -eq 0 ]; then
      log "  saved: $out  ($(human_bytes "$(stat -c%s "$out")"))"
      SAVED+=("$out"); DONE_REPOS+=("$repo")
      if [ "$API_FAIL" -gt 0 ]; then
        log "  ! saved with $API_FAIL API problem(s) - some issue/PR data is missing"
        WARN_REPOS+=("$owner/$repo")
      fi
    else
      log "  ! archiving failed: $(tail -n 2 "$TMP/arch.err" 2>/dev/null | tr '\n' ' ')${ARCH_LOST:+ - files that vanished while archiving: $ARCH_LOST}"; rm -f "$out"; FAILED_REPOS+=("$owner/$repo")
    fi
    CUR_OUT=""
    FRAC_PM=1000; ui_refresh force
    finish_repo
  }

  choose_repos "Backup repositories" "Tick the repositories to back up:" "$DEFAULT_CHECKED" 1 \
    || { echo "Nothing selected."; exit 0; }
  N=${#SELECTED[@]}
  mkdir -p "$OUT_DIR"
  progress_start "Full backup"

  for url in "${SELECTED[@]}"; do backup_repo "$url"; done

  summary
  finish_ui "Finished!"$'\n'"${#DONE_REPOS[@]} of $N repo(s) saved in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Failed: ${#FAILED_REPOS[@]}   With warnings: ${#WARN_REPOS[@]}"$'\n'"Saved in: $OUT_DIR"
  echo "Done."
  command -v notify-send >/dev/null && notify-send "Full backup finished" "${#DONE_REPOS[@]} of $N repo(s) saved (${#FAILED_REPOS[@]} failed, ${#WARN_REPOS[@]} with warnings)"
  exit $(( ${#FAILED_REPOS[@]} + ${#WARN_REPOS[@]} > 0 ? 1 : 0 ))
}

# ===========================================================================
# PRESET: code  (plain git clone: files + all branches + all tags)
# ===========================================================================
preset_code() {
  N=0; IDX=0; CUR_REPO=""; STAGE=""; DETAIL=""; FRAC_PM=0
  CUR_WORK=""; CUR_OUT=""; MEASURE_PATH=""
  CUR_BYTES=0; PREV_BYTES=0; LAST_BYTES=0; SPEED=0; LAST_UI_US=0
  DONE_REPOS=(); FAILED_REPOS=(); SAVED=()

  on_cleanup() {
    [ -n "$CUR_OUT" ] && rm -f "$CUR_OUT"
    [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"
  }

  summary() {
    local el=$((SECONDS-RUN_START)) f
    echo
    echo "================ Summary ================"
    echo " Repos saved    : ${#DONE_REPOS[@]} of $N"
    echo " Repos failed   : ${#FAILED_REPOS[@]}"
    echo " Data fetched   : $(human_bytes "$PREV_BYTES")"
    echo " Total time     : $(fmt_time "$el")"
    if [ "${#SAVED[@]}" -gt 0 ]; then
      echo " Archives:"; for f in "${SAVED[@]}"; do echo "   $f"; done
    fi
    if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
      echo " Failed:"; for f in "${FAILED_REPOS[@]}"; do echo "   $f"; done
    fi
    echo "========================================="
  }

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

    pm=$(( ((IDX-1)*1000 + FRAC_PM) / N ))
    [ "$pm" -gt 1000 ] && pm=1000
    el=$((SECONDS - RUN_START))
    if [ "$pm" -ge 20 ] && [ "$el" -ge 3 ]; then eta="~$(fmt_time $(( el * (1000-pm) / pm )))"; fi

    printf -v text '%s\n%s\n%s\n%s\n%s\n%s' \
      "Repository $IDX of $N:  $CUR_REPO" \
      "Step:  $STAGE${DETAIL:+   ($DETAIL)}" \
      "Speed:  $(human_bytes "$SPEED")/s        Fetched so far:  $(human_bytes $((PREV_BYTES + CUR_BYTES)))" \
      "Elapsed:  $(fmt_time "$el")        ETA (estimate):  $eta" \
      "Finished (${#DONE_REPOS[@]}):  $(tail_list DONE_REPOS)" \
      "Failed (${#FAILED_REPOS[@]}):  $(tail_list FAILED_REPOS)"
    progress_update $((pm/10)) "$text" || cancel_exit
    if [ -t 1 ]; then
      printf '\r\033[K  %s %3d%%  %s  %s/s  %s' "$(bar $((pm/10)) 16)" $((pm/10)) \
        "$(human_bytes $((PREV_BYTES + CUR_BYTES)))" "$(human_bytes "$SPEED")" "$STAGE"
    fi
  }

  # Turns git's own progress line ("Receiving objects:  45% (90/200)") into text and a percentage.
  git_progress() {
    local line pct
    line="$(tr '\r' '\n' < "$TMP/git.err" 2>/dev/null | grep -E '(Counting|Compressing|Receiving|Resolving|Checking|Updating)' | tail -n 1)"
    [ -z "$line" ] && return 0
    line="${line#remote: }"
    DETAIL="${line%%(*}"; DETAIL="${DETAIL%"${DETAIL##*[![:space:]]}"}"
    pct="$(grep -oE '[0-9]+%' <<<"$line" | head -n 1)"; pct="${pct%\%}"
    [[ "$pct" =~ ^[0-9]+$ ]] || return 0
    case "$line" in
      Counting*|Compressing*) FRAC_PM=$(( 100 + pct )) ;;      # 100..200
      Receiving*)             FRAC_PM=$(( 200 + pct * 5 )) ;;  # 200..700
      Resolving*)             FRAC_PM=$(( 700 + pct )) ;;      # 700..800
      Checking*|Updating*)    FRAC_PM=$(( 800 + pct )) ;;      # 800..900
    esac
  }

  finish_repo() {
    PREV_BYTES=$((PREV_BYTES + CUR_BYTES)); CUR_BYTES=0; LAST_BYTES=0
    MEASURE_PATH=""; [ -n "$CUR_WORK" ] && rm -rf "$CUR_WORK"; CUR_WORK=""
  }

  download_repo() {
    local url="$1" work dest target ts out rc gpid zpid zt nb nt
    local clone_args=()
    repo_parts "$url"; local owner="$OWNER" repo="$REPO"
    echo "== $owner/$repo"

    IDX=$((IDX+1)); CUR_REPO="$owner/$repo"
    STAGE="Preparing"; DETAIL=""; FRAC_PM=0; SPEED=0; LAST_BYTES=0; CUR_BYTES=0
    CUR_WORK="$(mktemp -d "$OUT_DIR/.code-work.XXXXXX")" || { log "  ! cannot create work folder in $OUT_DIR"; FAILED_REPOS+=("$owner/$repo"); return; }
    work="$CUR_WORK"; MEASURE_PATH="$work"
    if [ "$CLONE_MODE" = bare ]; then clone_args=(--bare); target="$repo.git"; else target="$repo"; fi
    dest="$work/$target"
    ui_refresh force

    # 1. git clone: files of the default branch + every branch + every tag
    STAGE="Cloning ($CLONE_MODE)"; FRAC_PM=100; ui_refresh force
    : > "$TMP/git.err"
    env "${GIT_ENV[@]}" git clone --progress ${clone_args[@]+"${clone_args[@]}"} \
      "https://github.com/$owner/$repo.git" "$dest" 2>"$TMP/git.err" &
    gpid=$!; CHILD_PID=$gpid
    while kill -0 "$gpid" 2>/dev/null; do
      git_progress; ui_refresh
      sleep 0.5
    done
    wait "$gpid"; rc=$?; CHILD_PID=""
    DETAIL=""
    if [ "$rc" -ne 0 ]; then
      log "  ! git clone failed: $(tr '\r' '\n' < "$TMP/git.err" | grep -E 'fatal|error' | tail -n 1)"
      FAILED_REPOS+=("$owner/$repo"); finish_repo; return
    fi

    # 2. Make sure every tag is there (a clone only follows tags that point into fetched branches)
    STAGE="Fetching all tags"; FRAC_PM=900; ui_refresh force
    env "${GIT_ENV[@]}" git -C "$dest" fetch --tags --force --quiet origin 2>"$TMP/git.err" \
      || log "  ! fetching tags reported a problem: $(tail -n 1 "$TMP/git.err")"
    if [ "$CLONE_MODE" = bare ]; then
      nb="$(git -C "$dest" for-each-ref --format='%(refname)' refs/heads | wc -l)"
    else
      nb="$(git -C "$dest" for-each-ref --format='%(refname)' refs/remotes/origin | grep -vc '/HEAD$')"
    fi
    nt="$(git -C "$dest" for-each-ref --format='%(refname)' refs/tags | wc -l)"
    log "  branches: $nb, tags: $nt"

    # 3. Archive into Downloads with a timestamp name
    STAGE="Compressing to ${ARCHIVE_FORMAT^^}"; FRAC_PM=930; ui_refresh force
    MEASURE_PATH=""
    ts="$(date +"%Y.%m.%d.%H.%M.%S")"
    out="$OUT_DIR/$ts - $repo - code.$ARCHIVE_EXT"; CUR_OUT="$out"
    make_archive "$work" "$target" "$out" "$([ "$CLONE_MODE" = bare ] && echo "$dest" || echo "$dest/.git")" 930 68; rc=$?
    if [ "$rc" -eq 0 ]; then
      log "  saved: $out  ($(human_bytes "$(stat -c%s "$out")"))"
      SAVED+=("$out"); DONE_REPOS+=("$repo")
    else
      log "  ! archiving failed: $(tail -n 2 "$TMP/arch.err" 2>/dev/null | tr '\n' ' ')${ARCH_LOST:+ - files that vanished while archiving: $ARCH_LOST}"; rm -f "$out"; FAILED_REPOS+=("$owner/$repo")
    fi
    CUR_OUT=""
    FRAC_PM=1000; ui_refresh force
    finish_repo
  }

  choose_repos "Download code (git clone)" "Tick the repositories to download:" "$DEFAULT_CHECKED" 1 \
    || { echo "Nothing selected."; exit 0; }
  N=${#SELECTED[@]}
  mkdir -p "$OUT_DIR"
  progress_start "Download code (git clone)"

  for url in "${SELECTED[@]}"; do download_repo "$url"; done

  summary
  finish_ui "Finished!"$'\n'"${#DONE_REPOS[@]} of $N repo(s) saved in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Failed: ${#FAILED_REPOS[@]}"$'\n'"Saved in: $OUT_DIR"
  echo "Done."
  command -v notify-send >/dev/null && notify-send "Code download finished" "${#DONE_REPOS[@]} of $N repo(s) saved to $OUT_DIR (${#FAILED_REPOS[@]} failed)"
  exit $(( ${#FAILED_REPOS[@]} > 0 ? 1 : 0 ))
}

# ===========================================================================
# PRESET: release  (latest release files; release-all ticks every repo by default)
# ===========================================================================
preset_release() {
  N=0; CURL_PID=""; CUR_PART=""
  TOTAL_BYTES=0; TOTAL_FILES=0; DONE_BYTES=0; FILES_OK=0; FILES_SKIPPED=0; FILES_FAILED=0
  DONE_REPOS=(); SKIPPED_REPOS=(); FAILED_ITEMS=(); FOLDERS=()
  DL_START_US=0

  # An unfinished *.part file is deliberately kept on cancel / error; the next run resumes it.
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
      echo " Saved in:"; for f in "${FOLDERS[@]}"; do echo "   $f"; done
    fi
    if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
      echo " Failed items (unfinished downloads resume on the next run):"
      for f in "${FAILED_ITEMS[@]}"; do echo "   $f"; done
    fi
    [ "$RATE_LIMITED" = 1 ] && echo " The GitHub API rate limit was hit - add a token and run again."
    echo "========================================="
  }

  release_ui() {   # uses: i, repo, rel_name, fidx, fcount, file, sz, size, spd
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

  choose_repos "Download latest releases" "Tick the repositories whose latest release you want:" "$DEFAULT_CHECKED" 1 \
    || { echo "Nothing selected."; exit 0; }
  N=${#SELECTED[@]}
  mkdir -p "$OUT_DIR"
  progress_start "Download latest releases"

  declare -a R_PATH R_SHORT R_REL R_FOLDER R_STATE R_COUNT R_ERR

  # ---- Phase 1: look up every release first (so the total size is known) ----
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
      norelease) log "  no published release";                      SKIPPED_REPOS+=("$repo"); continue ;;
      apierror)  log "  ! ${R_ERR[i]}"; FAILED_ITEMS+=("$repo: ${R_ERR[i]}"); continue ;;
      noassets)  log "  no attached files in this release";         SKIPPED_REPOS+=("$repo"); continue ;;
      nomatch)   log "  none of the assets matched ASSET_SUFFIXES"; SKIPPED_REPOS+=("$repo"); continue ;;
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

      rc=0; sz="$ps"; spd=0; file_t0=${EPOCHREALTIME/[.,]/}
      if [ "$ps" -lt "$size" ]; then
        curl -fL -sS ${AUTH[@]+"${AUTH[@]}"} -C - -o "$CUR_PART" "$dl" 2>"$TMP/curl.err" &
        CURL_PID=$!
        last_sz=$ps; last_t=${EPOCHREALTIME/[.,]/}
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
        fail_msg="download error $(head -c 200 "$TMP/curl.err" 2>/dev/null)"     # .part kept for resuming
      elif [ "$(stat -c%s "$CUR_PART")" != "$size" ]; then
        fail_msg="size mismatch (got $(stat -c%s "$CUR_PART"), expected $size)"; rm -f "$CUR_PART"
      elif ! verify_digest "$CUR_PART" "$digest"; then
        fail_msg="checksum mismatch (does not match GitHub's ${digest%%:*} digest)"; rm -f "$CUR_PART"
      fi

      if [ -z "$fail_msg" ]; then
        mv -f "$CUR_PART" "$folder/$file"; CUR_PART=""
        sz="$size"
        secs=$(( ( ${EPOCHREALTIME/[.,]/} - file_t0 ) / 1000000 )); [ "$secs" -lt 1 ] && secs=1
        release_ui                                                   # show 100% for this file ...
        DONE_BYTES=$((DONE_BYTES + size)); FILES_OK=$((FILES_OK+1))  # ... then count it as done
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

  summary
  finish_ui "Finished!"$'\n'"Downloaded $FILES_OK file(s), $(human_bytes "$DONE_BYTES") in $(fmt_time $((SECONDS-RUN_START)))"$'\n'"Failed: ${#FAILED_ITEMS[@]}"$'\n'"Saved in: $OUT_DIR"
  echo "Done."
  command -v notify-send >/dev/null && notify-send "Release download finished" "$FILES_OK file(s), $(human_bytes "$DONE_BYTES") - $N repo(s) processed, ${#FAILED_ITEMS[@]} failed"
  exit $(( ${#FAILED_ITEMS[@]} > 0 ? 1 : 0 ))
}

# ===========================================================================
# Running a preset and the menu
# ===========================================================================
# run_preset <backup|code|release-all|release>
# Runs in a subshell: the preset's exit / cancel only ends the run, not the menu.
run_preset() {
  local id="$1" req
  case "$id" in
    backup)      req="git curl jq $ARCH_CMD awk du stat base64 tr grep";  DEFAULT_CHECKED=TRUE ;;
    code)        req="git $ARCH_CMD awk du stat tr grep";              DEFAULT_CHECKED=TRUE ;;
    release-all) req="curl jq awk stat tr grep sed";                DEFAULT_CHECKED=TRUE ;;
    release)     req="curl jq awk stat tr grep sed";                DEFAULT_CHECKED=FALSE ;;
    *) echo "Unknown preset: $id" >&2; return 2 ;;
  esac
  # From the menu the preset runs in a subshell, so its exit or Cancel only ends the run.
  # With --preset it runs directly, so Ctrl+C / SIGTERM sent to this process reach its cleanup.
  if [ "$HAVE_PRESET" = 1 ]; then
    init_run "$req"; run_preset_body "$id"
  else
    ( init_run "$req"; run_preset_body "$id" )
  fi
}

run_preset_body() {
  case "$1" in
    backup)              preset_backup ;;
    code)                preset_code ;;
    release-all|release) preset_release ;;
  esac
}

main() {
  detect_gui
  load_repos
  load_format

  if [ "$HAVE_PRESET" = 1 ]; then
    case "$CLI_PRESET" in
      backup|code|release-all|release) ;;
      *) echo "Unknown preset: '$CLI_PRESET' (use backup, code, release-all or release)" >&2; exit 2 ;;
    esac
    run_preset "$CLI_PRESET"
    exit $?
  fi

  local choice
  while :; do
    choice="$(ui_menu "repo-tool" "What do you want to do? (${#REPOS[@]} repositories in the list, archives: ${ARCHIVE_FORMAT^^})" \
      backup       "Full backup: code, branches, tags, issues, PRs and all comments (one archive per repo)" \
      code         "Code only: plain git clone with all branches and tags (one archive per repo)" \
      release-all  "Latest release files (matching the suffix list), all repos ticked by default" \
      release      "Latest release files (matching the suffix list), no repos ticked by default" \
      format       "Archive format: ${ARCHIVE_FORMAT^^}  (switch to $([ "$ARCHIVE_FORMAT" = zip ] && echo "RAR, ${RAR_RECOVERY}% recovery record" || echo ZIP))" \
      add          "Add repositories to the list..." \
      remove       "Remove repositories from the list..." \
      view         "Show the repository list" \
      reset        "Restore the built-in repository list" \
      quit         "Quit")" || break
    case "$choice" in
      backup|code|release-all|release) run_preset "$choice" ;;
      format) toggle_format_flow ;;
      add)    add_repos_flow ;;
      remove) remove_repos_flow ;;
      view)   view_repos ;;
      reset)  reset_repos ;;
      quit|"") break ;;
    esac
  done
}

main

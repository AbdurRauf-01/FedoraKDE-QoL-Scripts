#!/usr/bin/env python3
"""
GitHub repo tool (GUI) for KDE - port of repo-tool.sh.

Pick a job (full backup / code only / latest release files), tick the repositories,
set options, and the real work runs in Konsole. Nothing heavy runs inside this window.
The repository list is shared with the old script (~/.config/repo-tool/repos.txt).

Requires: konsole, git, curl, jq, zip (and rar for RAR archives), and
PyQt6 or PySide6  (sudo dnf install python3-pyqt6).

GitHub token: GITHUB_TOKEN or the first line of ~/.config/github-token. It is read by
the job in the terminal, never typed into this window, never written to the job script.

Optional command line (pre-selects things in the window, nothing runs by itself):
  --preset NAME   backup | code | release-all | release
  --format F      zip | rar (for this session only; the dropdown remembers your last pick)
  --all           tick every repository
"""
import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

try:
    from PyQt6 import QtCore as C, QtWidgets as W
except ImportError:
    try:
        from PySide6 import QtCore as C, QtWidgets as W
    except ImportError:
        sys.exit("PyQt6 or PySide6 not found. Install with: sudo dnf install python3-pyqt6")

CHECKED = C.Qt.CheckState.Checked
UNCHECKED = C.Qt.CheckState.Unchecked
USER_ROLE = C.Qt.ItemDataRole.UserRole
USER_CHECKABLE = C.Qt.ItemFlag.ItemIsUserCheckable

# ------------------------------------------------------------- defaults ---
# (everything you may want to tweak lives in this block)
APP_TITLE = "GitHub Repo Tool"

OUT_DIR = "~/Downloads"          # where archives / release folders are written
CONFIG_DIR = "~/.config/repo-tool"   # repos.txt and "format" live here (shared with repo-tool.sh)
TOKEN_FILE = "~/.config/github-token"

DEF_PRESET = "backup"            # backup | code | release-all | release
DEF_FORMAT = "zip"               # zip | rar   (used until you pick one in the window)
DEF_RAR_LEVEL = "3"              # 3 = Normal
DEF_RAR_RECOVERY = 20            # percent, 0 = Off
DEF_CLONE_MODE = "normal"        # normal = working copy, bare = repository data only

# Release presets: only assets whose file name ENDS with one of these are downloaded
# (case-insensitive). Empty = every asset. Editable in the window.
ASSET_SUFFIXES = [
    "-linux-x86_64.flatpak",
    "-windows-x64.msi",
    "-linux-x86_64.flatpak.asc",
    "-windows-x64.msi.asc",
]

# Built-in list: written on first run, and by "Restore built-in list".
DEFAULT_REPOS = [
    "https://github.com/storytold/artcraft",
    "https://github.com/storytold/craft-launcher",
    "https://github.com/storytold/artcraft-services",
    "https://github.com/storytold/photocraft",
    "https://github.com/storytold/lightcraft",
    "https://github.com/storytold/filmcraft",
    "https://github.com/storytold/vectorcraft",
    "https://github.com/storytold/pdfcraft",
    "https://github.com/storytold/effectcraft",
    "https://github.com/storytold/designcraft",
    "https://github.com/storytold/figcraft",
    "https://github.com/storytold/soundcraft",
    "https://github.com/storytold/cadcraft",
    "https://github.com/storytold/texturecraft",
    "https://github.com/storytold/materialcraft",
    "https://github.com/storytold/wordcraft",
    "https://github.com/storytold/deckcraft",
    "https://github.com/storytold/gridcraft",
    "https://github.com/storytold/craft-anything",
    "https://github.com/tangency-labs/solidcraft",
]

# (id, label, ticked-by-default)
PRESETS = [
    ("backup", "Full backup - git mirror, issues, pull requests, all comments", True),
    ("code", "Code only - git clone with all branches and tags", True),
    ("release-all", "Latest release files - all repositories ticked", True),
    ("release", "Latest release files - nothing ticked, you pick", False),
]
ARCHIVE_PRESETS = ("backup", "code")

FORMATS = [("ZIP", "zip"), ("RAR", "rar")]
RAR_LEVELS = [
    ("Store (no compression)", "0"), ("Fastest", "1"), ("Fast", "2"),
    ("Normal", "3"), ("Good", "4"), ("Best", "5"),
]
CLONE_MODES = [
    ("Working copy - files, all branches and tags", "normal"),
    ("Bare - repository data only (smaller; restore with git clone)", "bare"),
]

RAR_HINT = (
    "RAR is proprietary software, so the 'rar' command has to be installed separately:\n"
    "  Fedora:         sudo dnf install rar     (needs the RPM Fusion nonfree repository)\n"
    "  Debian/Ubuntu:  sudo apt install rar\n"
    "  or download it from https://www.rarlab.com/download.htm"
)

# Commands each job needs (the archiver - zip or rar - is added for backup/code).
REQUIRED = {
    "backup": ["git", "curl", "jq", "awk", "du", "stat", "base64", "tr", "grep"],
    "code": ["git", "awk", "du", "stat", "base64", "tr", "grep"],
    "release-all": ["curl", "jq", "awk", "stat", "tr", "grep", "sed", "base64"],
    "release": ["curl", "jq", "awk", "stat", "tr", "grep", "sed", "base64"],
}
GENERAL_TOOLS = sorted({t for v in REQUIRED.values() for t in v})
DNF_PACKAGE = {"awk": "gawk", "du": "coreutils", "stat": "coreutils",
               "base64": "coreutils", "tr": "coreutils"}


# ---------------------------------------------------------------- helpers ---
def q(s):
    return shlex.quote(s)


def bash_array(name, values):
    return f"{name}=(" + " ".join(q(v) for v in values) + ")"


def required_tools(preset, fmt):
    tools = list(REQUIRED[preset])
    if preset in ARCHIVE_PRESETS:
        tools.append(fmt)
    return tools


def missing_message(missing, fmt):
    lines = ["Missing from PATH: " + ", ".join(missing)]
    dnf = sorted({DNF_PACKAGE.get(t, t) for t in missing if t != "rar"})
    if dnf:
        lines.append("Install with:  sudo dnf install " + " ".join(dnf))
    if "rar" in missing:
        lines += ["", RAR_HINT, "", "Or switch the archive format to ZIP."]
    return "\n".join(lines)


def token_status():
    """Only checks that a token exists; the token itself is never read here."""
    if os.environ.get("GITHUB_TOKEN", "").strip():
        return "found (GITHUB_TOKEN)"
    try:
        if os.path.getsize(os.path.expanduser(TOKEN_FILE)) > 0:
            return f"found ({TOKEN_FILE})"
    except OSError:
        pass
    return "none - 60 API requests/hour, private repositories unreachable"


def short_name(url):
    return url.removeprefix("https://github.com/")


# ------------------------------------------------- repository list (file) ---
def repo_list_path():
    return os.path.join(os.path.expanduser(CONFIG_DIR), "repos.txt")


def format_file_path():
    return os.path.join(os.path.expanduser(CONFIG_DIR), "format")


def normalize_repo(s):
    """Accepts https://github.com/o/r (also http, www., .git, trailing /), github.com/o/r,
    git@github.com:o/r.git or plain o/r. Returns the normalized URL or None."""
    s = "".join(s.split())
    for prefix in ("https://", "http://", "www.", "github.com/", "git@github.com:"):
        s = s.removeprefix(prefix)
    s = s.removesuffix("/").removesuffix(".git").removesuffix("/")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", s):
        return None
    if any(part in (".", "..") for part in s.split("/")):
        return None
    return "https://github.com/" + s


def save_repos(repos):
    path = repo_list_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# GitHub repositories for repo-tool - one per line. "
                "Lines starting with # are ignored.\n")
        for r in repos:
            f.write(r + "\n")
    os.replace(tmp, path)


def load_repos():
    """Returns (repos, problems). Creates the file from DEFAULT_REPOS on first run."""
    path = repo_list_path()
    problems = []
    if not os.path.isfile(path):
        try:
            save_repos(DEFAULT_REPOS)
        except OSError as e:
            problems.append(f"cannot write {path}: {e}")
            return list(DEFAULT_REPOS), problems
    repos = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = "".join(line.split("#", 1)[0].split())
                if not line:
                    continue
                url = normalize_repo(line)
                if url is None:
                    problems.append(f"ignored invalid line: {line}")
                elif url not in repos:
                    repos.append(url)
    except OSError as e:
        problems.append(f"cannot read {path}: {e}")
    return repos, problems


def load_format():
    try:
        with open(format_file_path(), encoding="utf-8") as f:
            v = f.readline().strip()
        if v in ("zip", "rar"):
            return v
    except OSError:
        pass
    return None


def save_format(fmt):
    path = format_file_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(fmt + "\n")


# ------------------------------------------------------------ job script ---
HEADER = ["#!/usr/bin/env bash", 'SELF="$0"', "trap 'rm -f -- \"$SELF\"' EXIT"]

# The static part of the job script. Everything the GUI chooses arrives as variables /
# arrays defined above it (all built with shlex.quote), so nothing here is interpolated.
WORKER = r'''
set -u

TOKEN_FILE="$HOME/.config/github-token"
TMP=""; CHILD_PID=""; CURL_PID=""; RUN_START=$SECONDS
AUTH=(); GIT_ENV=(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0 GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false)
RATE_LIMITED=0; HTTP_CODE=000; ARCH_LOST=""
N=${#SELECTED[@]}; IDX=0; STAGE=""; DETAIL=""; FRAC_PM=0
CUR_WORK=""; CUR_OUT=""; CUR_PART=""; MEASURE_PATH=""
CUR_BYTES=0; PREV_BYTES=0; LAST_BYTES=0; SPEED=0; LAST_UI_US=0
ISSUES="?"; PRS="?"; API_FAIL=0
DONE_REPOS=(); FAILED_REPOS=(); WARN_REPOS=(); SKIPPED_REPOS=(); SAVED=()
TOTAL_BYTES=0; TOTAL_FILES=0; DONE_BYTES=0; FILES_OK=0; FILES_SKIPPED=0; FILES_FAILED=0
FAILED_ITEMS=(); FOLDERS=(); DL_START_US=0; REPLACE_ALL=0

case "$ARCHIVE_FORMAT" in
  rar) ARCHIVE_EXT=rar; ARCH_CMD=rar ;;
  *)   ARCHIVE_FORMAT=zip; ARCHIVE_EXT=zip; ARCH_CMD=zip ;;
esac

RAR_HINT="RAR is proprietary software, so the 'rar' command has to be installed separately:
  Fedora:         sudo dnf install rar     (needs the RPM Fusion nonfree repository)
  Debian/Ubuntu:  sudo apt install rar
  or download it from https://www.rarlab.com/download.htm"

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

status_line() {   # one status line cut to the terminal width, replacing the previous one
  local cols="${COLUMNS:-}"
  [ -n "$cols" ] || cols="$(tput cols 2>/dev/null || echo 80)"
  printf '\r\033[K%s' "${1:0:$((cols-1))}"
}

bar() {   # bar <percent> <width>
  local p=$1 w=${2:-20} f e
  f=$((p*w/100)); e=$((w-f))
  printf '[%s%s]' "$(printf '%*s' "$f" '' | tr ' ' '#')" "$(printf '%*s' "$e" '' | tr ' ' '-')"
}

repo_parts() {   # repo_parts <url> -> sets OWNER and REPO
  local p="$1"
  p="${p#https://github.com/}"; p="${p%/}"; p="${p%.git}"
  OWNER="${p%%/*}"; REPO="${p#*/}"
}

# Remove characters that are not allowed in folder names
sanitize() {
  printf '%s' "$1" | tr -d '/\\:*?"<>|\n\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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
      [ "$(sha256sum -- "$1" | cut -d' ' -f1)" = "${2#sha256:}" ] ;;
    *) return 0 ;;
  esac
}

# Asks before replacing a file that exists with a different size. Returns 0 = replace.
confirm_replace() {   # confirm_replace <path> <size on disk> <size on GitHub>
  local a
  [ "$REPLACE_ALL" = 1 ] && return 0
  [ -t 0 ] || return 1
  log "  ! already exists with a different size: $1 ($2 bytes here, $3 bytes on GitHub)"
  read -r -p "    Replace it? [y]es / [N]o / [a]ll: " a || return 1
  case "$a" in
    [Aa]*) REPLACE_ALL=1; return 0 ;;
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

# ===========================================================================
# Cleanup, summaries, interrupts
# ===========================================================================
on_cleanup() { :; }      # each job replaces this with its own temp-file cleanup

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; fi
  if [ -n "$CURL_PID" ];  then kill "$CURL_PID"  2>/dev/null; fi
  on_cleanup
  [ -n "$TMP" ] && rm -rf -- "$TMP"
  rm -f -- "$SELF"
  echo; echo "Finished (exit code $rc). You can close this window."
}

summary_archive() {
  local el=$((SECONDS-RUN_START)) f
  echo
  echo "================ Summary ================"
  echo " Created        : ${#DONE_REPOS[@]} of $N"
  [ "$PRESET" = backup ] && echo " With warnings  : ${#WARN_REPOS[@]}"
  echo " Failed         : ${#FAILED_REPOS[@]}"
  echo " Skipped        : ${#SKIPPED_REPOS[@]}  (archive name already existed)"
  echo " Data fetched   : $(human_bytes "$PREV_BYTES")"
  echo " Total time     : $(fmt_time "$el")"
  if [ "${#SAVED[@]}" -gt 0 ]; then
    echo " Archives:"; for f in "${SAVED[@]}"; do echo "   $f"; done
  fi
  if [ "${#WARN_REPOS[@]}" -gt 0 ]; then
    echo " Saved, but some GitHub API data is missing:"; for f in "${WARN_REPOS[@]}"; do echo "   $f"; done
  fi
  if [ "${#SKIPPED_REPOS[@]}" -gt 0 ]; then
    echo " Skipped:"; for f in "${SKIPPED_REPOS[@]}"; do echo "   $f"; done
  fi
  if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
    echo " Failed:"; for f in "${FAILED_REPOS[@]}"; do echo "   $f"; done
  fi
  [ "$RATE_LIMITED" = 1 ] && echo " The GitHub API rate limit was hit - add a token and run again."
  echo "========================================="
}

summary_release() {
  local el=$((SECONDS-RUN_START)) avg=0 f
  [ "$el" -gt 0 ] && avg=$((DONE_BYTES/el))
  echo
  echo "================ Summary ================"
  echo " Created (downloaded) : $FILES_OK  ($(human_bytes "$DONE_BYTES"))"
  echo " Failed               : $FILES_FAILED"
  echo " Skipped              : $FILES_SKIPPED  (already present / kept)"
  echo " Repos without files  : ${#SKIPPED_REPOS[@]}  (no release / no matching files)"
  echo " Time / avg speed     : $(fmt_time "$el")  /  $(human_bytes "$avg")/s"
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

summary() {
  case "$PRESET" in
    backup|code) summary_archive ;;
    *)           summary_release ;;
  esac
}

on_interrupt() {
  echo; echo "Interrupted."
  summary
  exit 130
}

trap '' PIPE
trap cleanup EXIT
trap on_interrupt INT TERM HUP

init_run() {
  local cmd token
  for cmd in $REQ; do
    if ! command -v "$cmd" >/dev/null; then
      if [ "$cmd" = rar ]; then
        echo "Missing dependency: rar"; echo "$RAR_HINT"; echo "Or use ZIP instead (archive format dropdown in the window)."
      else
        echo "Missing dependency: $cmd  (install it, e.g. sudo dnf install $cmd)"
      fi
      exit 1
    fi
  done
  TMP="$(mktemp -d)" || exit 1

  token="${GITHUB_TOKEN:-$(head -n 1 "$TOKEN_FILE" 2>/dev/null || true)}"
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
# make_archive <work-dir> <entry> <output-file> <git-dir> <progress-base-permille> <progress-span-permille>
# Returns 0 on success; ARCH_LOST holds the first vanished files if it kept failing.
# ---------------------------------------------------------------------------
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
  local work="$1" entry="$2" out="$3" gitdir="$4" base="$5" span="$6" attempt rc zpid zt l
  local rar_opts=(-idq -y -r -ol -ma5 "-m$RAR_LEVEL")
  [ "$RAR_RECOVERY" -gt 0 ] && rar_opts+=("-rr${RAR_RECOVERY}%")
  ARCH_LOST=""
  for attempt in 1 2 3; do
    wait_git_quiet "$gitdir"
    find "$work/$entry" -mindepth 1 2>/dev/null | LC_ALL=C sort > "$TMP/arch.before"
    rm -f -- "$out"
    if [ "$ARCHIVE_FORMAT" = rar ]; then
      ( cd -- "$work" && exec rar a "${rar_opts[@]}" -- "$out" "$entry" >"$TMP/arch.err" 2>&1 ) &
    else
      # zip only accepts "--" after the archive name
      ( cd -- "$work" && exec zip -qry "$out" -- "$entry" 2>"$TMP/arch.err" ) &
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
        rar t -idq -- "$out" >/dev/null 2>&1 || rc=1
      elif command -v unzip >/dev/null; then
        unzip -tqq -- "$out" >/dev/null 2>&1 || rc=1
      fi
    fi
    [ "$rc" -eq 0 ] && return 0

    # which files were in the folder before archiving but are gone now?
    find "$work/$entry" -mindepth 1 2>/dev/null | LC_ALL=C sort > "$TMP/arch.after"
    ARCH_LOST="$(LC_ALL=C comm -23 "$TMP/arch.before" "$TMP/arch.after" | head -n 5 \
      | while IFS= read -r l; do printf '%s ' "${l#"$work"/}"; done)"
    # zip exit 18 / rar exit 1 (warning) or 6 (open error): a file could not be read
    if { [ "$ARCHIVE_FORMAT" = zip ] && [ "$rc" -eq 18 ]; } || { [ "$ARCHIVE_FORMAT" = rar ] && { [ "$rc" -eq 1 ] || [ "$rc" -eq 6 ]; }; }; then
      if [ "$attempt" -lt 3 ]; then
        log "  ! could not read some files (exit $rc${ARCH_LOST:+, vanished: $ARCH_LOST}) - trying again ($((attempt+1)) of 3)"
        sleep 3; continue
      fi
    fi
    break
  done
  rm -f -- "$out"
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
# Console progress line (speed from the size of MEASURE_PATH), at most twice a second
# ---------------------------------------------------------------------------
ui_refresh() {
  local force="${1:-}" t dt inst pm el eta="--:--:--" out line
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
  [ "$pm" -lt 0 ] && pm=0
  el=$((SECONDS - RUN_START))
  if [ "$pm" -ge 20 ] && [ "$el" -ge 3 ]; then eta="~$(fmt_time $(( el * (1000-pm) / pm )))"; fi

  if [ -t 1 ]; then
    printf -v line '  %s %3d%%  [%d/%d]  %s  %s/s  ETA %s  %s' "$(bar $((pm/10)) 12)" $((pm/10)) \
      "$IDX" "$N" "$(human_bytes $((PREV_BYTES + CUR_BYTES)))" "$(human_bytes "$SPEED")" "$eta" "$STAGE"
    status_line "$line"
  fi
}

finish_repo() {
  PREV_BYTES=$((PREV_BYTES + CUR_BYTES)); CUR_BYTES=0; LAST_BYTES=0
  MEASURE_PATH=""; [ -n "$CUR_WORK" ] && rm -rf -- "$CUR_WORK"; CUR_WORK=""
}

finish_run() {   # finish_run <title> <summary-line>
  summary
  echo "Done."
  command -v notify-send >/dev/null && notify-send "$1" "$2"
}

# ===========================================================================
# JOB: backup  (full backup: mirror + issues + PRs + all comments + reviews)
# ===========================================================================
preset_backup() {
  on_cleanup() {
    [ -n "$CUR_OUT" ] && rm -f -- "$CUR_OUT"
    [ -n "$CUR_WORK" ] && rm -rf -- "$CUR_WORK"
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
    mkdir -p -- "$outdir"
    jq -r --arg f "$field" \
      'group_by(.[$f] // "")[] | ((.[0][$f] // "" | split("/") | last) + "\t" + tojson)' "$src" |
    while IFS=$'\t' read -r n json; do
      [ -n "$n" ] && printf '%s\n' "$json" | jq . > "$outdir/$n.json"
    done
  }

  backup_repo() {
    local url="$1" api work dest ts out est_kb est f i n total rc gpid
    local pnums=() conv_n
    repo_parts "$url"; local owner="$OWNER" repo="$REPO"
    api="https://api.github.com/repos/$owner/$repo"
    echo "== $owner/$repo"

    IDX=$((IDX+1)); ISSUES="?"; PRS="?"; API_FAIL=0
    STAGE="Preparing"; DETAIL=""; FRAC_PM=0; SPEED=0; LAST_BYTES=0; CUR_BYTES=0
    # work inside the output folder, not /tmp (which can be a small RAM disk)
    CUR_WORK="$(mktemp -d "$OUT_DIR/.backup-work.XXXXXX")" || { log "  ! cannot create work folder in $OUT_DIR"; FAILED_REPOS+=("$owner/$repo"); CUR_WORK=""; return; }
    work="$CUR_WORK"
    dest="$work/$repo"; mkdir -p -- "$dest"
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
    env "${GIT_ENV[@]}" git clone --mirror --quiet -- \
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
    mkdir -p -- "$dest/issues/comments"
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
    mkdir -p -- "$dest/pulls/conversation" "$dest/pulls/review-comments" "$dest/pulls/reviews"
    api_get_all "$api/pulls" "state=all" "$dest/pulls/pulls.json"
    PRS="$(jq length "$dest/pulls/pulls.json")"
    jq -r '.[].number' "$dest/pulls/pulls.json" > "$TMP/prnums"

    DETAIL="review comments"; FRAC_PM=850; ui_refresh force
    api_get_all "$api/pulls/comments" "" "$TMP/rc_all.json"
    split_by_number "$TMP/rc_all.json" pull_request_url "$dest/pulls/review-comments"

    # sort the conversation comments: numbers that are PRs -> pulls/conversation, the rest -> issues
    rm -rf -- "$TMP/conv"; split_by_number "$TMP/conv_all.json" issue_url "$TMP/conv"
    for f in "$TMP/conv"/*.json; do
      [ -e "$f" ] || continue
      conv_n="${f##*/}"; conv_n="${conv_n%.json}"
      if grep -qxF "$conv_n" "$TMP/prnums"; then mv -f -- "$f" "$dest/pulls/conversation/$conv_n.json"
      else mv -f -- "$f" "$dest/issues/comments/$conv_n.json"; fi
    done
    rm -f -- "$TMP/issues_all.json" "$TMP/conv_all.json" "$TMP/rc_all.json"

    mapfile -t pnums < "$TMP/prnums"
    total=${#pnums[@]}; i=0
    for n in ${pnums[@]+"${pnums[@]}"}; do
      i=$((i+1)); DETAIL="reviews of PR #$n  ($i/$total)"
      FRAC_PM=$(( 870 + 100 * i / total )); ui_refresh
      api_get_all "$api/pulls/$n/reviews" "" "$dest/pulls/reviews/$n.json"
      [ "$(jq length "$dest/pulls/reviews/$n.json" 2>/dev/null)" = "0" ] && rm -f -- "$dest/pulls/reviews/$n.json"
    done
    log "  pull requests: $PRS"

    jq -n --arg repo "$owner/$repo" --arg when "$(date -Is)" \
          --argjson issues "${ISSUES//[^0-9]/0}" --argjson prs "${PRS//[^0-9]/0}" --argjson errors "$API_FAIL" \
      '{repository:$repo, backed_up_at:$when, issues:$issues, pull_requests:$prs, api_errors:$errors,
        note:"api_errors > 0 means some issue/PR data could not be fetched"}' > "$dest/backup-info.json"

    # 5. Archive into the output folder with a timestamp name (never over an existing file)
    DETAIL=""; STAGE="Compressing to ${ARCHIVE_FORMAT^^}"; FRAC_PM=970; ui_refresh force
    MEASURE_PATH=""
    ts="$(date +"%Y.%m.%d.%H.%M.%S")"
    out="$OUT_DIR/$ts - $repo.$ARCHIVE_EXT"
    if [ -e "$out" ]; then
      log "  SKIP (already exists): $out"; SKIPPED_REPOS+=("$owner/$repo"); finish_repo; return
    fi
    CUR_OUT="$out"
    make_archive "$work" "$repo" "$out" "$dest/git-mirror.git" 970 28; rc=$?
    if [ "$rc" -eq 0 ]; then
      log "  saved: $out  ($(human_bytes "$(stat -c%s -- "$out")"))"
      SAVED+=("$out"); DONE_REPOS+=("$repo")
      if [ "$API_FAIL" -gt 0 ]; then
        log "  ! saved with $API_FAIL API problem(s) - some issue/PR data is missing"
        WARN_REPOS+=("$owner/$repo")
      fi
    else
      log "  ! archiving failed: $(tail -n 2 "$TMP/arch.err" 2>/dev/null | tr '\n' ' ')${ARCH_LOST:+ - files that vanished while archiving: $ARCH_LOST}"; rm -f -- "$out"; FAILED_REPOS+=("$owner/$repo")
    fi
    CUR_OUT=""
    FRAC_PM=1000; ui_refresh force
    finish_repo
  }

  local url
  for url in "${SELECTED[@]}"; do backup_repo "$url"; done

  echo
  finish_run "Full backup finished" "${#DONE_REPOS[@]} of $N repo(s) saved (${#FAILED_REPOS[@]} failed, ${#WARN_REPOS[@]} with warnings, ${#SKIPPED_REPOS[@]} skipped)"
  exit $(( ${#FAILED_REPOS[@]} + ${#WARN_REPOS[@]} > 0 ? 1 : 0 ))
}

# ===========================================================================
# JOB: code  (plain git clone: files + all branches + all tags)
# ===========================================================================
preset_code() {
  on_cleanup() {
    [ -n "$CUR_OUT" ] && rm -f -- "$CUR_OUT"
    [ -n "$CUR_WORK" ] && rm -rf -- "$CUR_WORK"
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

  download_repo() {
    local url="$1" work dest target ts out rc gpid nb nt gitdir
    local clone_args=()
    repo_parts "$url"; local owner="$OWNER" repo="$REPO"
    echo "== $owner/$repo"

    IDX=$((IDX+1))
    STAGE="Preparing"; DETAIL=""; FRAC_PM=0; SPEED=0; LAST_BYTES=0; CUR_BYTES=0
    CUR_WORK="$(mktemp -d "$OUT_DIR/.code-work.XXXXXX")" || { log "  ! cannot create work folder in $OUT_DIR"; FAILED_REPOS+=("$owner/$repo"); CUR_WORK=""; return; }
    work="$CUR_WORK"; MEASURE_PATH="$work"
    if [ "$CLONE_MODE" = bare ]; then clone_args=(--bare); target="$repo.git"; else target="$repo"; fi
    dest="$work/$target"
    ui_refresh force

    # 1. git clone: files of the default branch + every branch + every tag
    STAGE="Cloning ($CLONE_MODE)"; FRAC_PM=100; ui_refresh force
    : > "$TMP/git.err"
    env "${GIT_ENV[@]}" git clone --progress ${clone_args[@]+"${clone_args[@]}"} -- \
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

    # 3. Archive into the output folder with a timestamp name (never over an existing file)
    STAGE="Compressing to ${ARCHIVE_FORMAT^^}"; FRAC_PM=930; ui_refresh force
    MEASURE_PATH=""
    ts="$(date +"%Y.%m.%d.%H.%M.%S")"
    out="$OUT_DIR/$ts - $repo - code.$ARCHIVE_EXT"
    if [ -e "$out" ]; then
      log "  SKIP (already exists): $out"; SKIPPED_REPOS+=("$owner/$repo"); finish_repo; return
    fi
    CUR_OUT="$out"
    if [ "$CLONE_MODE" = bare ]; then gitdir="$dest"; else gitdir="$dest/.git"; fi
    make_archive "$work" "$target" "$out" "$gitdir" 930 68; rc=$?
    if [ "$rc" -eq 0 ]; then
      log "  saved: $out  ($(human_bytes "$(stat -c%s -- "$out")"))"
      SAVED+=("$out"); DONE_REPOS+=("$repo")
    else
      log "  ! archiving failed: $(tail -n 2 "$TMP/arch.err" 2>/dev/null | tr '\n' ' ')${ARCH_LOST:+ - files that vanished while archiving: $ARCH_LOST}"; rm -f -- "$out"; FAILED_REPOS+=("$owner/$repo")
    fi
    CUR_OUT=""
    FRAC_PM=1000; ui_refresh force
    finish_repo
  }

  local url
  for url in "${SELECTED[@]}"; do download_repo "$url"; done

  echo
  finish_run "Code download finished" "${#DONE_REPOS[@]} of $N repo(s) saved to $OUT_DIR (${#FAILED_REPOS[@]} failed, ${#SKIPPED_REPOS[@]} skipped)"
  exit $(( ${#FAILED_REPOS[@]} > 0 ? 1 : 0 ))
}

# ===========================================================================
# JOB: release  (latest release files; release-all vs release only differ in the
# window, where the first ticks every repository by default)
# ===========================================================================
preset_release() {
  # An unfinished *.part file is deliberately kept on cancel / error; the next run resumes it.
  on_cleanup() {
    [ -n "$CURL_PID" ] && kill "$CURL_PID" 2>/dev/null
  }

  release_ui() {   # uses: i, N, sz, size, spd
    local cur=$((DONE_BYTES + sz)) pct=0 fpct=0 now el eta="--:--:--" avg line
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
    if [ -t 1 ]; then
      printf -v line '  %s %3d%%  %s / %s  %s/s  ETA %s  (all %d%%)' "$(bar "$fpct" 12)" "$fpct" \
        "$(human_bytes "$sz")" "$(human_bytes "$size")" "$(human_bytes "$spd")" "$eta" "$pct"
      status_line "$line"
    fi
  }

  declare -a R_PATH R_SHORT R_REL R_FOLDER R_STATE R_COUNT R_ERR
  local i

  # ---- Phase 1: look up every release first (so the total size is known) ----
  echo "Checking latest releases ($N repos)..."
  for ((i=0; i<N; i++)); do
    repo_parts "${SELECTED[i]}"; owner="$OWNER"; repo="$REPO"
    R_PATH[i]="$owner/$repo"; R_SHORT[i]="$repo"; R_REL[i]=""; R_FOLDER[i]=""
    R_STATE[i]="norelease"; R_COUNT[i]=0; R_ERR[i]=""

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
    nm=0; nq=0
    while IFS=$'\t' read -r -u 5 file dl size digest; do
      case "$file" in
        ''|.|..|*/*) log "  ! $owner/$repo: ignoring asset with an unsafe name: $file"; continue ;;
      esac
      want_asset "$file" || continue
      nm=$((nm+1))
      if [ -e "$folder/$file" ] && [ ! -f "$folder/$file" ]; then
        log "  ! exists but is not a regular file, skipping: $file"; FILES_SKIPPED=$((FILES_SKIPPED+1)); continue
      fi
      if [ -f "$folder/$file" ]; then
        have="$(stat -c%s -- "$folder/$file")"
        if [ "$have" != "$size" ]; then
          # never replace a different file without asking
          if ! confirm_replace "$folder/$file" "$have" "$size"; then
            log "  keeping the existing file: $file"; FILES_SKIPPED=$((FILES_SKIPPED+1)); continue
          fi
        else
          # complete already: phase 2 reports it as skipped; it does not count towards the total
          printf '%s\t%s\t%s\t%s\n' "$file" "$dl" "$size" "$digest" >> "$TMP/$i.assets"; nq=$((nq+1))
          continue
        fi
      fi
      printf '%s\t%s\t%s\t%s\n' "$file" "$dl" "$size" "$digest" >> "$TMP/$i.assets"; nq=$((nq+1))
      TOTAL_BYTES=$((TOTAL_BYTES + size)); TOTAL_FILES=$((TOTAL_FILES + 1))
    done 5< <(jq -r '.assets[] | [.name, .browser_download_url, (.size|tostring), (.digest // "-")] | @tsv' <<<"$json")

    R_COUNT[i]=$nq
    if [ "$nm" -eq 0 ]; then
      R_STATE[i]="nomatch"; log "  $owner/$repo: none of the $total assets matched the suffix list"
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
      norelease) log "  no published release";                       SKIPPED_REPOS+=("$repo"); continue ;;
      apierror)  log "  ! ${R_ERR[i]}"; FAILED_ITEMS+=("$repo: ${R_ERR[i]}"); continue ;;
      noassets)  log "  no attached files in this release";          SKIPPED_REPOS+=("$repo"); continue ;;
      nomatch)   log "  none of the assets matched the suffix list"; SKIPPED_REPOS+=("$repo"); continue ;;
    esac
    echo "  release: $rel_name"

    fcount="${R_COUNT[i]}"; fidx=0; repo_failed=0
    while IFS=$'\t' read -r -u 4 file dl size digest; do
      fidx=$((fidx+1))
      mkdir -p -- "$folder"
      if [ -f "$folder/$file" ] && [ "$(stat -c%s -- "$folder/$file")" = "$size" ]; then
        log "  already exists, skipping: $file"; FILES_SKIPPED=$((FILES_SKIPPED+1)); continue
      fi

      # resume an earlier unfinished download if there is one
      CUR_PART="$folder/$file.part"; ps=0
      [ -f "$CUR_PART" ] && ps="$(stat -c%s -- "$CUR_PART")"
      if [ "$ps" -gt "$size" ]; then rm -f -- "$CUR_PART"; ps=0; fi
      if [ "$ps" -gt 0 ]; then log "  downloading: $file ($(human_bytes "$size"), resuming at $(human_bytes "$ps"))"
      else log "  downloading: $file ($(human_bytes "$size"))"; fi

      rc=0; sz="$ps"; spd=0; file_t0=${EPOCHREALTIME/[.,]/}
      if [ "$ps" -lt "$size" ]; then
        curl -fL -sS ${AUTH[@]+"${AUTH[@]}"} -C - -o "$CUR_PART" "$dl" 2>"$TMP/curl.err" &
        CURL_PID=$!
        last_sz=$ps; last_t=${EPOCHREALTIME/[.,]/}
        while kill -0 "$CURL_PID" 2>/dev/null; do
          sz="$(stat -c%s -- "$CUR_PART" 2>/dev/null || echo 0)"
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
      elif [ "$(stat -c%s -- "$CUR_PART")" != "$size" ]; then
        fail_msg="size mismatch (got $(stat -c%s -- "$CUR_PART"), expected $size)"; rm -f -- "$CUR_PART"
      elif ! verify_digest "$CUR_PART" "$digest"; then
        fail_msg="checksum mismatch (does not match GitHub's ${digest%%:*} digest)"; rm -f -- "$CUR_PART"
      fi

      if [ -z "$fail_msg" ]; then
        mv -f -- "$CUR_PART" "$folder/$file"; CUR_PART=""
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

    [ -d "$folder" ] && FOLDERS+=("$folder")
    [ "$repo_failed" -eq 0 ] && DONE_REPOS+=("$repo")
    echo "  matched $fcount file(s) -> $folder"
  done

  echo
  finish_run "Release download finished" "$FILES_OK file(s), $(human_bytes "$DONE_BYTES") - $N repo(s) processed, ${#FAILED_ITEMS[@]} failed"
  exit $(( ${#FAILED_ITEMS[@]} > 0 ? 1 : 0 ))
}

# ===========================================================================
# Run
# ===========================================================================
case "$PRESET" in
  backup)              REQ="git curl jq $ARCH_CMD awk du stat base64 tr grep"; JOB=preset_backup ;;
  code)                REQ="git $ARCH_CMD awk du stat base64 tr grep";         JOB=preset_code ;;
  release-all|release) REQ="curl jq awk stat tr grep sed base64";              JOB=preset_release ;;
  *) echo "Unknown preset: $PRESET" >&2; exit 2 ;;
esac

init_run
echo "Job: $PRESET   repositories: $N   output: $OUT_DIR"
mkdir -p -- "$OUT_DIR" || { echo "Cannot create $OUT_DIR"; exit 1; }
"$JOB"
'''


def build_script(preset, fmt, clone_mode, out_dir, rar_level, rar_recovery, repos, suffixes):
    """Header with every choice as a quoted variable / array, then the static worker."""
    lines = HEADER + [
        f"PRESET={q(preset)}",
        f"ARCHIVE_FORMAT={q(fmt)}",
        f"CLONE_MODE={q(clone_mode)}",
        f"OUT_DIR={q(out_dir)}",
        f"RAR_LEVEL={q(str(rar_level))}",
        f"RAR_RECOVERY={q(str(rar_recovery))}",
        bash_array("SELECTED", repos),
        bash_array("ASSET_SUFFIXES", suffixes),
    ]
    return "\n".join(lines) + "\n" + WORKER


def set_item_enabled(combo, index, enabled):
    try:
        item = combo.model().item(index)
        if item is not None:
            item.setEnabled(enabled)
    except AttributeError:
        pass


# ------------------------------------------------------------------- GUI ---
class Window(W.QWidget):
    def __init__(self, args=None):
        super().__init__()
        from_cli = args or argparse.Namespace(preset=None, format=None, all=False)
        self.setWindowTitle(APP_TITLE)
        self.setMinimumWidth(740)
        self.last_dir = os.path.expanduser(OUT_DIR)
        self.ticks_manual = False      # True once the user has changed a tick themselves
        self._loading = False
        self.have = {t: bool(shutil.which(t)) for t in set(GENERAL_TOOLS) | {"zip", "rar"}}
        self.repos, problems = load_repos()

        root = W.QVBoxLayout(self)

        self.banner = W.QLabel()
        self.banner.setWordWrap(True)
        self.banner.setStyleSheet("QLabel { color: #d9534f; }")
        root.addWidget(self.banner)

        # --- repositories
        g_repos = W.QGroupBox("Repositories")
        l_repos = W.QVBoxLayout(g_repos)
        add_row = W.QHBoxLayout()
        self.add_edit = W.QLineEdit()
        self.add_edit.setPlaceholderText(
            "Add: paste GitHub links or owner/repo names, separated by spaces or commas")
        self.add_edit.setToolTip("Accepted: https://github.com/o/r (also http, www., .git, trailing /),\n"
                                 "github.com/o/r, git@github.com:o/r.git or plain o/r.\n"
                                 "New repositories are ticked and saved to the list at once.")
        self.add_edit.returnPressed.connect(self.add_from_text)
        add_btn = W.QPushButton("Add")
        add_btn.clicked.connect(lambda checked=False: self.add_from_text())
        add_row.addWidget(self.add_edit)
        add_row.addWidget(add_btn)
        l_repos.addLayout(add_row)

        self.listw = W.QListWidget()
        self.listw.setSelectionMode(W.QAbstractItemView.SelectionMode.ExtendedSelection)
        self.listw.setMinimumHeight(210)
        self.listw.setToolTip("Tick = process this repository.\n"
                              "Highlighted rows are what 'Remove selected' takes out of the list.")
        self.listw.itemChanged.connect(self.on_item_changed)
        l_repos.addWidget(self.listw)

        row = W.QHBoxLayout()
        for text, fn in (
            ("Tick all", lambda: self.tick_all(True)),
            ("Tick none", lambda: self.tick_all(False)),
            ("Remove selected", self.remove_selected),
            ("Restore built-in list…", self.restore_defaults),
        ):
            b = W.QPushButton(text)
            b.clicked.connect(lambda checked=False, f=fn: f())
            row.addWidget(b)
        l_repos.addLayout(row)
        self.status = W.QLabel()
        self.status.setWordWrap(True)
        l_repos.addWidget(self.status)
        root.addWidget(g_repos)

        # --- job
        g_job = W.QGroupBox("Job")
        f_job = W.QFormLayout(g_job)
        self.preset = W.QComboBox()
        for pid, label, _ in PRESETS:
            self.preset.addItem(label, pid)
        self.preset.setToolTip(
            "Full backup: git mirror (all branches, tags, PR refs) + issues + pull requests +\n"
            "  every comment and review, one archive per repository.\n"
            "Code only: plain git clone (files, all branches, all tags), one archive per\n"
            "  repository. No API calls, so no rate limit.\n"
            "Latest release files: downloads the newest published release's files whose names\n"
            "  match the suffix list. The two entries differ only in what is ticked at first.")
        self.preset.currentIndexChanged.connect(self.on_preset_changed)
        f_job.addRow("Preset:", self.preset)

        dir_row = W.QHBoxLayout()
        self.out_edit = W.QLineEdit(os.path.expanduser(OUT_DIR))
        self.out_edit.setToolTip("Created if missing. Archives are named "
                                 "'<timestamp> - <repo>.zip/.rar'; release files go to one "
                                 "'<repo> - <release>' folder each.")
        browse = W.QPushButton("Browse…")
        browse.clicked.connect(lambda checked=False: self.browse_out())
        dir_row.addWidget(self.out_edit)
        dir_row.addWidget(browse)
        f_job.addRow("Save in:", dir_row)
        root.addWidget(g_job)

        # --- options
        g_opt = W.QGroupBox("Options")
        f_opt = W.QFormLayout(g_opt)

        self.fmt = W.QComboBox()
        for label, val in FORMATS:
            self.fmt.addItem(label, val)
        self.fmt.setToolTip("Archive format for Full backup and Code only.\n"
                            "Your choice is remembered. RAR needs the proprietary 'rar' command.")
        self.fmt.currentIndexChanged.connect(self.on_fmt_changed)
        self.fmt.activated.connect(self.on_fmt_activated)   # user picks only -> remembered
        f_opt.addRow("Archive format:", self.fmt)

        self.rar_level = W.QComboBox()
        for label, val in RAR_LEVELS:
            self.rar_level.addItem(label, val)
        self.rar_level.setCurrentIndex(self.rar_level.findData(DEF_RAR_LEVEL))
        f_opt.addRow("RAR compression:", self.rar_level)

        self.rar_rr = W.QSpinBox()
        self.rar_rr.setRange(0, 100)
        self.rar_rr.setSuffix(" %")
        self.rar_rr.setSpecialValueText("Off")
        self.rar_rr.setValue(DEF_RAR_RECOVERY)
        self.rar_rr.setToolTip("Recovery record: lets RAR repair a damaged archive.")
        f_opt.addRow("RAR recovery record:", self.rar_rr)

        self.clone = W.QComboBox()
        for label, val in CLONE_MODES:
            self.clone.addItem(label, val)
        self.clone.setCurrentIndex(self.clone.findData(DEF_CLONE_MODE))
        self.clone.setToolTip("Code only. Working copy = the default branch's files plus all branches\n"
                              "and tags inside .git. Bare = repository data only.")
        f_opt.addRow("Code download:", self.clone)

        self.suffixes = W.QPlainTextEdit("\n".join(ASSET_SUFFIXES))
        self.suffixes.setPlaceholderText("One suffix per line. Empty = download every file.")
        self.suffixes.setMaximumHeight(92)
        self.suffixes.setToolTip("Release downloads only. A file is downloaded when its name ENDS with one\n"
                                 "of these (case-insensitive). Empty list = every file of the release.")
        f_opt.addRow("Release file suffixes:", self.suffixes)

        self.token_lbl = W.QLabel(token_status())
        self.token_lbl.setToolTip("GITHUB_TOKEN, or the first line of ~/.config/github-token. Needed for\n"
                                  "private repositories; avoids the 60-requests-per-hour limit.\n"
                                  "It is read by the job in Konsole, never by this window.")
        f_opt.addRow("GitHub token:", self.token_lbl)
        root.addWidget(g_opt)

        # --- buttons
        btns = W.QHBoxLayout()
        self.run_note = W.QLabel()
        btns.addWidget(self.run_note, 1)
        cancel = W.QPushButton("Cancel")
        cancel.clicked.connect(lambda checked=False: self.close())
        self.go = W.QPushButton("Start")
        self.go.setDefault(True)
        self.go.clicked.connect(lambda checked=False: self.start())
        btns.addWidget(cancel)
        btns.addWidget(self.go)
        root.addLayout(btns)

        # --- initial state
        self.init_formats(from_cli.format)
        self.refresh_banner()
        if from_cli.preset:
            self.preset.setCurrentIndex(self.preset.findData(from_cli.preset))
        else:
            self.preset.setCurrentIndex(self.preset.findData(DEF_PRESET))
        self.fill_list()
        self.on_preset_changed()
        if from_cli.all:
            self.tick_all(True)
        if problems:
            self.say("\n".join(problems))
        else:
            self.update_count()

    # ---- helpers
    def error(self, msg):
        W.QMessageBox.warning(self, APP_TITLE, msg)

    def say(self, msg):
        self.status.setText(msg)

    def ticked_urls(self):
        out = []
        for i in range(self.listw.count()):
            it = self.listw.item(i)
            if it.checkState() == CHECKED:
                out.append(it.data(USER_ROLE))
        return out

    def update_count(self):
        self.say(f"{len(self.repos)} repositories in the list, {len(self.ticked_urls())} ticked.")

    # ---- availability of tools
    def init_formats(self, cli_format):
        self._loading = True
        for i, (_, val) in enumerate(FORMATS):
            ok = self.have[val]
            set_item_enabled(self.fmt, i, ok)
            if not ok:
                self.fmt.setItemText(i, f"{FORMATS[i][0]} ('{val}' not installed)")
        wanted = cli_format or load_format() or DEF_FORMAT
        note = ""
        if not self.have[wanted]:
            other = "zip" if wanted == "rar" else "rar"
            if self.have[other]:
                note = f"'{wanted}' is not installed - using {other.upper()}.\n" + (
                    RAR_HINT if wanted == "rar" else "")
                wanted = other
        self.fmt.setCurrentIndex(self.fmt.findData(wanted))
        self._loading = False
        self.format_note = note
        tip = self.fmt.toolTip()
        if not self.have["rar"]:
            tip += "\n\n" + RAR_HINT
        self.fmt.setToolTip(tip)

    def refresh_banner(self):
        missing = [t for t in GENERAL_TOOLS if not self.have[t]]
        parts = []
        if missing:
            parts.append("Some tools are missing, so jobs that need them cannot run.\n"
                         + missing_message(missing, "zip"))
        if not self.have["zip"] and not self.have["rar"]:
            parts.append("Neither 'zip' nor 'rar' is installed: Full backup and Code only cannot "
                         "create archives.\nInstall zip with: sudo dnf install zip")
        if getattr(self, "format_note", ""):
            parts.append(self.format_note)
        self.banner.setText("\n\n".join(parts))
        self.banner.setVisible(bool(parts))

    # ---- repository list
    def fill_list(self):
        ticked = self.default_ticked()
        self._loading = True
        self.listw.clear()
        for url in self.repos:
            self.add_list_item(url, ticked)
        self._loading = False
        self.update_count()

    def add_list_item(self, url, checked):
        it = W.QListWidgetItem(short_name(url))
        it.setData(USER_ROLE, url)
        it.setFlags(it.flags() | USER_CHECKABLE)
        it.setCheckState(CHECKED if checked else UNCHECKED)
        self.listw.addItem(it)

    def default_ticked(self):
        pid = self.preset.currentData()
        return next((d for p, _, d in PRESETS if p == pid), True)

    def set_all_ticks(self, checked):
        self._loading = True
        for i in range(self.listw.count()):
            self.listw.item(i).setCheckState(CHECKED if checked else UNCHECKED)
        self._loading = False
        self.update_count()

    def tick_all(self, checked):
        self.ticks_manual = True
        self.set_all_ticks(checked)

    def on_item_changed(self, _item):
        if self._loading:
            return
        self.ticks_manual = True
        self.update_count()

    def persist_repos(self):
        try:
            save_repos(self.repos)
            return True
        except OSError as e:
            self.error(f"Could not save the repository list:\n{e}")
            return False

    def add_from_text(self):
        text = self.add_edit.text()
        if not text.strip():
            return
        added, dup, bad = [], [], []
        for tok in text.replace(",", " ").split():
            url = normalize_repo(tok)
            if url is None:
                bad.append(tok)
            elif url in self.repos or url in added:
                dup.append(short_name(url))
            else:
                added.append(url)
        if added:
            self.repos.extend(added)
            self._loading = True
            for url in added:
                self.add_list_item(url, True)
            self._loading = False
            self.ticks_manual = True
            self.persist_repos()
            self.listw.scrollToBottom()
        # leave only what was not understood in the box, so it can be fixed
        self.add_edit.setText(" ".join(bad))
        msg = f"Added ({len(added)}): " + (", ".join(short_name(u) for u in added) or "none")
        if dup:
            msg += f"\nAlready in the list ({len(dup)}): " + ", ".join(dup)
        if bad:
            msg += f"\nNot understood ({len(bad)}), left in the box: " + ", ".join(bad)
        msg += f"\n{len(self.repos)} repositories in the list, {len(self.ticked_urls())} ticked."
        self.say(msg)

    def remove_selected(self):
        rows = sorted({self.listw.row(i) for i in self.listw.selectedItems()}, reverse=True)
        if not rows:
            self.say("Highlight the repositories to remove first (click, Ctrl/Shift-click).")
            return
        gone = []
        for r in rows:
            url = self.listw.item(r).data(USER_ROLE)
            gone.append(short_name(url))
            self.repos.remove(url)
            self.listw.takeItem(r)
        self.persist_repos()
        self.say(f"Removed from the list ({len(gone)}): " + ", ".join(reversed(gone))
                 + f"\nNothing is deleted from your disk. {len(self.repos)} repositories in the "
                   f"list, {len(self.ticked_urls())} ticked.")

    def restore_defaults(self):
        ans = W.QMessageBox.question(
            self, "Restore built-in list",
            f"Replace the current list with the {len(DEFAULT_REPOS)} built-in repositories?\n"
            "Repositories you added will be removed from the list.")
        if ans != W.QMessageBox.StandardButton.Yes:
            return
        self.repos = [normalize_repo(u) for u in DEFAULT_REPOS]
        if self.persist_repos():
            self.fill_list()
            self.say(f"The list now holds the {len(self.repos)} built-in repositories.")

    # ---- output folder
    def browse_out(self):
        # Qt's own dialog (not the native KDE one) so the files in each folder stay visible.
        start = self.out_edit.text().strip() or self.last_dir
        dlg = W.QFileDialog(self, "Save in", start if os.path.isdir(start) else self.last_dir)
        dlg.setFileMode(W.QFileDialog.FileMode.Directory)
        dlg.setOption(W.QFileDialog.Option.DontUseNativeDialog, True)
        dlg.setOption(W.QFileDialog.Option.ShowDirsOnly, False)
        if dlg.exec():
            sel = dlg.selectedFiles()
            if sel:
                self.out_edit.setText(sel[0])
                self.last_dir = sel[0]

    # ---- option interplay
    def on_preset_changed(self, *_):
        pid = self.preset.currentData()
        archive = pid in ARCHIVE_PRESETS
        self.fmt.setEnabled(archive)
        self.clone.setEnabled(pid == "code")
        self.suffixes.setEnabled(pid.startswith("release"))
        self.on_fmt_changed()
        if not self.ticks_manual:
            self.set_all_ticks(self.default_ticked())
        self.go.setText("Start download" if pid.startswith("release") else
                        "Start backup" if pid == "backup" else "Start code download")

    def on_fmt_changed(self, *_):
        rar = self.preset.currentData() in ARCHIVE_PRESETS and self.fmt.currentData() == "rar"
        self.rar_level.setEnabled(rar)
        self.rar_rr.setEnabled(rar)

    def on_fmt_activated(self, *_):
        if self._loading:
            return
        try:
            save_format(self.fmt.currentData())
        except OSError as e:
            self.say(f"Could not remember the archive format: {e}")

    # ---- run
    def start(self):
        pid = self.preset.currentData()
        repos = self.ticked_urls()
        if not repos:
            self.error("Tick at least one repository first.")
            return
        fmt = self.fmt.currentData()
        missing = [t for t in required_tools(pid, fmt) if not shutil.which(t)]
        if missing:
            self.error(missing_message(missing, fmt))
            return
        text = self.out_edit.text().strip()
        if not text:
            self.error("Enter the folder to save into.")
            return
        out_dir = os.path.abspath(os.path.expanduser(text))
        if os.path.exists(out_dir) and not os.path.isdir(out_dir):
            self.error(f"{out_dir}\nexists but is not a folder.")
            return
        try:
            os.makedirs(out_dir, exist_ok=True)
        except OSError as e:
            self.error(f"Cannot create {out_dir}:\n{e}")
            return
        if not os.access(out_dir, os.W_OK | os.X_OK):
            self.error(f"No permission to write in\n{out_dir}")
            return
        suffixes = [s.strip() for s in self.suffixes.toPlainText().splitlines() if s.strip()]
        if pid.startswith("release") and not suffixes:
            ans = W.QMessageBox.question(
                self, "No suffix filter",
                "The suffix list is empty, so EVERY file of each latest release will be "
                "downloaded. Continue?")
            if ans != W.QMessageBox.StandardButton.Yes:
                return
        script = build_script(pid, fmt, self.clone.currentData(), out_dir,
                              self.rar_level.currentData(), self.rar_rr.value(), repos, suffixes)
        self.launch(script, len(repos))

    def launch(self, script, n):
        fd, path = tempfile.mkstemp(prefix="repo-tool-gui-", suffix=".sh")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(script)
        os.chmod(path, 0o700)
        try:
            subprocess.Popen(["konsole", "--hold", "-e", "bash", path], start_new_session=True)
        except OSError as e:
            os.remove(path)
            self.error(f"Could not start Konsole:\n{e}")
            return
        # The window stays open (the repository list is a long-lived thing); close it with Cancel.
        self.run_note.setText(f"Started in Konsole ({n} repositor{'y' if n == 1 else 'ies'}).")


def parse_args(argv):
    ap = argparse.ArgumentParser(
        description="GitHub repo tool (GUI). Options only pre-select things in the window.")
    ap.add_argument("--preset", choices=[p[0] for p in PRESETS], help="pre-select a job")
    ap.add_argument("--format", choices=["zip", "rar"], help="archive format for this session")
    ap.add_argument("--all", action="store_true", help="tick every repository")
    return ap.parse_known_args(argv)


def main():
    args, qt_args = parse_args(sys.argv[1:])
    app = W.QApplication([sys.argv[0]] + qt_args)
    if not shutil.which("konsole"):
        W.QMessageBox.critical(None, APP_TITLE,
                               "Not found in PATH: konsole\nInstall with: sudo dnf install konsole")
        return 1
    win = Window(args)
    win.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())

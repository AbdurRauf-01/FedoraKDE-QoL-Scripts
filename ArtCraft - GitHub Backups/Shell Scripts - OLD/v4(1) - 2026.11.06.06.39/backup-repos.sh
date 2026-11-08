#!/usr/bin/env bash
# Full git mirror + repo metadata + issues + pull requests (with comments and reviews).
# No wiki, no releases. Output: ~/Downloads/"yyyy.MM.dd.hh.mm.ss - repo.zip"
# Opens a console window, a repo selection dialog (all repos ticked by default) and a live progress window.

# ---- Opens its own console window when started without one (double-click / launcher).
if [ ! -t 1 ] && [ -z "${REPO_TOOL_IN_TERM:-}" ] && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
  export REPO_TOOL_IN_TERM=1
  _self="$(readlink -f "${BASH_SOURCE[0]}")"
  _wrap='bash "$0" "$@"; rc=$?; echo; read -rp "Finished (exit code $rc). Press Enter to close this window... " _'
  for _t in konsole gnome-terminal xfce4-terminal kitty alacritty xterm; do
    command -v "$_t" >/dev/null 2>&1 || continue
    case "$_t" in
      gnome-terminal) exec gnome-terminal -- bash -c "$_wrap" "$_self" "$@" ;;
      xfce4-terminal) exec xfce4-terminal -x bash -c "$_wrap" "$_self" "$@" ;;
      kitty)          exec kitty bash -c "$_wrap" "$_self" "$@" ;;
      *)              exec "$_t" -e bash -c "$_wrap" "$_self" "$@" ;;
    esac
  done
fi

set -u

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

# Size of the repository selection dialog (pixels).
DIALOG_WIDTH=820
DIALOG_HEIGHT=760

OUT_DIR="$HOME/Downloads"
TOKEN_FILE="$HOME/.config/github-token"
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

AUTH=()
GIT_AUTH=()
if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
  GIT_AUTH=(-c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)")
fi

# ======================= shared helpers: dialogs, progress window, cleanup =======================
STATE="$(mktemp -d)"            # scratch dir the progress window reads its numbers from
START_TS="$(date +%s)"
WORKDIRS=()                     # temp dirs removed on exit
SELECTED=()
PROG_BACKEND=""
SKIP_LABEL="Skipped"
CURRENT_PART=""
N_DONE=0; N_FAIL=0; N_SKIP=0; RECENT=""; FAILED=""

HAVE_ZENITY=0;  command -v zenity  >/dev/null 2>&1 && HAVE_ZENITY=1
HAVE_KDIALOG=0; command -v kdialog >/dev/null 2>&1 && HAVE_KDIALOG=1

cleanup() {
  [ "${CLEANED:-0}" = 1 ] && return
  CLEANED=1
  [ -n "${MON_PID:-}" ] && kill "$MON_PID" 2>/dev/null
  [ -n "$CURRENT_PART" ] && rm -f "$CURRENT_PART"
  local d
  for d in "${WORKDIRS[@]+"${WORKDIRS[@]}"}"; do rm -rf "$d"; done
  rm -rf "$STATE"
}
on_signal() {
  echo; echo "Interrupted - cleaning up..."
  [ -n "${ZEN_PID:-}" ] && kill "$ZEN_PID" 2>/dev/null
  [ "$PROG_BACKEND" = kdialog ] && kd_call close
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM HUP

# ---- tiny state store shared with the progress monitor (atomic writes)
st()   { printf '%s' "$2" > "$STATE/.$1.tmp" && mv -f "$STATE/.$1.tmp" "$STATE/$1"; }
sget() { cat "$STATE/$1" 2>/dev/null; }

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}
    if(i==1)printf "%d %s",b,u[i]; else printf "%.1f %s",b,u[i]}'
}
human_time() {
  local s=${1:-0}; [ "$s" -lt 0 ] && s=0
  if [ "$s" -ge 3600 ]; then printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
  else printf '%02d:%02d' $((s/60)) $((s%60)); fi
}

# ---- repository checklist (zenity if installed, otherwise kdialog) -> fills SELECTED
select_repos() {
  local title="$1" u out state="off" rows=() geo=()
  [ "$DEFAULT_CHECKED" = "TRUE" ] && state="on"
  if [ "$HAVE_ZENITY" = 1 ]; then
    for u in "${REPOS[@]}"; do rows+=("$DEFAULT_CHECKED" "${u#https://github.com/}" "$u"); done
    out="$(zenity --list --checklist --title="$title" \
      --text="Tick the repositories to process, then press OK:" \
      --column="Pick" --column="Repository" --column="URL" \
      --hide-column=3 --print-column=3 --separator=$'\n' \
      --width="$DIALOG_WIDTH" --height="$DIALOG_HEIGHT" "${rows[@]}")" || exit 0
  elif [ "$HAVE_KDIALOG" = 1 ]; then
    # Only pass --geometry if this kdialog build knows it (an unknown option would abort the dialog).
    if kdialog --help-all 2>&1 | grep -q -- '--geometry'; then
      geo=(--geometry "${DIALOG_WIDTH}x${DIALOG_HEIGHT}")
    fi
    for u in "${REPOS[@]}"; do rows+=("$u" "${u#https://github.com/}" "$state"); done
    echo "Tip: 'sudo dnf install zenity' gives a larger selection dialog and a live progress window."
    out="$(kdialog ${geo[@]+"${geo[@]}"} --title "$title" --separate-output \
      --checklist "Tick the repositories to process:" "${rows[@]}")" || exit 0
  else
    echo "Install zenity or kdialog for the selection dialog (sudo dnf install zenity)."
    exit 1
  fi
  [ -z "$out" ] && { echo "Nothing selected."; exit 0; }
  mapfile -t SELECTED <<<"$out"
}

# ---- progress window plumbing
kd_call() { "$QDBUS" $KD_REF "$@" >/dev/null 2>&1; }

gui_set() {   # $1 = percent, $2 = text
  case "$PROG_BACKEND" in
    zenity)
      local t="$2"; t="${t//\\/\\\\}"; t="${t//$'\n'/\\n}"
      ( trap '' PIPE; printf '%s\n# %s\n' "$1" "$t" ) >&9 2>/dev/null ;;
    kdialog)
      kd_call Set "" value "$1"; kd_call setLabelText "$2" ;;
  esac
}

# Background loop: measures bytes on disk once a second and redraws the window.
progress_monitor() {
  local watch kind cur base received maxrecv=0 inst speed=0 total ptotal pbase pspan est sub pct
  local now elapsed dl0 active avg eta remain head det ntotal ndone nfail nskip nrem recent failed text
  while [ ! -e "$STATE/stop" ]; do
    sleep 1
    [ -e "$STATE/stop" ] && break
    watch="$(sget watch)"; kind="$(sget watchkind)"; cur=0
    if [ -n "$watch" ]; then
      if [ "$kind" = file ]; then cur="$(stat -c %s "$watch" 2>/dev/null)"
      else cur="$(du -sb "$watch" 2>/dev/null | cut -f1)"; fi
      cur="${cur:-0}"
    fi
    base="$(sget base_received)"; base="${base:-0}"
    received=$((base + cur))
    [ "$received" -lt "$maxrecv" ] && received=$maxrecv      # never go backwards
    inst=$((received - maxrecv)); maxrecv=$received
    speed=$(( (speed + inst) / 2 ))                           # light smoothing

    total="$(sget total_bytes)"; total="${total:-0}"
    ptotal="$(sget pct_total)";  ptotal="${ptotal:-0}"
    if [ "$total" -gt 0 ]; then
      pct=$(( received * 100 / total ))
    elif [ "$ptotal" -gt 0 ]; then
      pbase="$(sget pct_base)"; pbase="${pbase:-0}"
      pspan="$(sget pct_span)"; pspan="${pspan:-0}"
      est="$(sget est_bytes)"
      if [ -n "$est" ] && [ "$est" -gt 0 ] && [ -n "$watch" ]; then
        sub=$(( cur * 100 / est )); [ "$sub" -gt 99 ] && sub=99
      else
        sub="$(sget sub)"; sub="${sub:-0}"
      fi
      pct=$(( (pbase * 100 + pspan * sub) / ptotal ))
    else
      pct=0
    fi
    [ "$pct" -gt 99 ] && pct=99

    now="$(date +%s)"; elapsed=$((now - START_TS))
    dl0="$(sget dl_start)"; dl0="${dl0:-$START_TS}"
    eta="--:--"
    if [ "$total" -gt 0 ] && [ "$received" -gt 0 ]; then
      active=$((now - dl0)); [ "$active" -lt 1 ] && active=1
      avg=$(( received / active ))
      remain=$((total - received)); [ "$remain" -lt 0 ] && remain=0
      [ "$avg" -gt 0 ] && eta="~$(human_time $((remain / avg)))"
    elif [ "$pct" -ge 3 ]; then
      eta="~$(human_time $(( elapsed * (100 - pct) / pct )))"
    fi

    head="$(sget headline)"; det="$(sget detail)"
    ntotal="$(sget n_total)"; ntotal="${ntotal:-0}"
    ndone="$(sget n_done)";   ndone="${ndone:-0}"
    nfail="$(sget n_fail)";   nfail="${nfail:-0}"
    nskip="$(sget n_skip)";   nskip="${nskip:-0}"
    recent="$(sget recent)";  failed="$(sget failed_list)"
    nrem=$((ntotal - ndone - nfail - nskip)); [ "$nrem" -lt 0 ] && nrem=0

    text="$head"$'\n'"$det"$'\n\n'"Completed: $ndone"
    [ "$nskip" -gt 0 ] && text+="   $SKIP_LABEL: $nskip"
    text+="   Failed: $nfail   Remaining: $nrem (incl. current)"
    [ -n "$recent" ] && text+=$'\n'"Latest finished: $recent"
    [ -n "$failed" ] && text+=$'\n'"Failed: ${failed:0:150}"
    text+=$'\n\n'"Speed: $(human_bytes "$speed")/s    Received: $(human_bytes "$received")"
    [ "$total" -gt 0 ] && text+=" of $(human_bytes "$total")"
    text+=$'\n'"Elapsed: $(human_time "$elapsed")    ETA: $eta    Progress: ${pct}%"
    text+=$'\n\n'"(Press Ctrl+C in the console window to cancel)"
    gui_set "$pct" "$text"
  done
}

progress_start() {   # $1 = window title
  st base_received 0
  if [ "$HAVE_ZENITY" = 1 ] && mkfifo "$STATE/prog.fifo" 2>/dev/null; then
    zenity --progress --title="$1" --text="Starting..." --percentage=0 \
      --no-cancel --no-markup --width=640 < "$STATE/prog.fifo" >/dev/null 2>&1 &
    ZEN_PID=$!
    exec 9>"$STATE/prog.fifo"
    PROG_BACKEND=zenity
  elif [ "$HAVE_KDIALOG" = 1 ]; then
    local q
    for q in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
      command -v "$q" >/dev/null 2>&1 && { QDBUS="$q"; break; }
    done
    if [ -z "${QDBUS:-}" ]; then
      echo "(no qdbus found - progress window disabled, console output only; try: sudo dnf install zenity)"
      return 0
    fi
    KD_REF="$(kdialog --title "$1" --progressbar "Starting..." 100 2>/dev/null)" || return 0
    PROG_BACKEND=kdialog
  else
    return 0
  fi
  progress_monitor &
  MON_PID=$!
}

# Stops the live updates, shows the final summary, waits for the user to dismiss it.
progress_done() {   # $1 = summary text
  if [ -n "${MON_PID:-}" ]; then
    touch "$STATE/stop"; wait "$MON_PID" 2>/dev/null; MON_PID=""
  fi
  case "$PROG_BACKEND" in
    zenity)  gui_set 100 "$1"; echo "Click OK in the progress window to finish."; wait "$ZEN_PID" 2>/dev/null ;;
    kdialog) gui_set 100 "$1"; sleep 6; kd_call close ;;
  esac
}

# ---- what the monitor measures (a growing file or folder) and bookkeeping
watch_file() { st watchkind file; st watch "$1"; }
watch_dir()  { st watchkind dir;  st watch "$1"; }
watch_end()  {   # $1 = final size in bytes of what was being watched
  local b; st watch ""
  b="$(sget base_received)"; st base_received $(( ${b:-0} + ${1:-0} ))
}

sync_counts() { st n_done "$N_DONE"; st n_fail "$N_FAIL"; st n_skip "$N_SKIP"; st recent "$RECENT"; st failed_list "$FAILED"; }
mark_done() { N_DONE=$((N_DONE + 1)); RECENT="$1${RECENT:+, $RECENT}"; RECENT="$(cut -d, -f1-3 <<<"$RECENT")"; sync_counts; }
mark_fail() { N_FAIL=$((N_FAIL + 1)); FAILED="${FAILED:+$FAILED, }$1"; sync_counts; }
mark_skip() { N_SKIP=$((N_SKIP + 1)); sync_counts; }

for cmd in git curl jq zip; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

# Fetch every page of a list endpoint and print one merged JSON array.
# $1 = endpoint URL, $2 = optional query string (e.g. "state=all")
api_get_all() {
  local url="$1" extra="${2:-}" page=1 tmp resp
  tmp="$(mktemp)"
  while :; do
    resp="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
      "${url}?${extra:+$extra&}per_page=100&page=${page}")" \
      || { echo "  ! API error: $url (page $page)" >&2; break; }
    [ "$(jq 'length' <<<"$resp")" -eq 0 ] && break
    printf '%s\n' "$resp" >> "$tmp"
    page=$((page + 1))
  done
  jq -s 'add // []' "$tmp"
  rm -f "$tmp"
}

# Moves the progress window on to the next step of the current repo.
# $1 = label, $2 = share of this repo's progress (all steps add up to 100)
set_step() {
  st detail "Step: $1"
  st pct_base "$((REPO_BASE + STEP_OFF))"; st pct_span "$2"
  st sub 0; st est_bytes ""
  STEP_OFF=$((STEP_OFF + $2))
}

backup_repo() {
  local url="$1" path owner repo api work dest ts out size_kb n i num c rc label
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  api="https://api.github.com/repos/$owner/$repo"
  label="$owner/$repo"
  echo "== $label"

  REPO_BASE=$((REPO_IDX * 100)); STEP_OFF=0
  st headline "Repository $((REPO_IDX + 1)) of $N_TOTAL: $label"

  work="$(mktemp -d)"; WORKDIRS+=("$work")
  dest="$work/$repo"; mkdir -p "$dest"
  watch_dir "$work"

  # 1. Repo metadata (description, topics, settings, size)
  set_step "Fetching repository info" 2
  curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" "$api" \
    > "$dest/repo.json" || echo "  ! repo metadata failed"
  size_kb="$(jq -r '.size // 0' "$dest/repo.json" 2>/dev/null)"
  [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

  # 2. Full git mirror: all branches, tags, and pull request refs
  set_step "Cloning full git mirror (branches, tags, PR refs)" 45
  [ "$size_kb" -gt 0 ] && st est_bytes "$((size_kb * 1024))"
  if ! git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} clone --mirror --progress \
       "https://github.com/$owner/$repo.git" "$dest/git-mirror.git"; then
    echo "  ! git clone failed"
    watch_end "$(du -sb "$work" 2>/dev/null | cut -f1)"
    rm -rf "$work"; mark_fail "$repo"; return
  fi

  # 3. Issues. The issues endpoint also returns PRs, so filter them out.
  set_step "Downloading issues" 20
  mkdir -p "$dest/issues/comments"
  api_get_all "$api/issues" "state=all" \
    | jq 'map(select(has("pull_request") | not))' > "$dest/issues/issues.json"
  n="$(jq '[.[] | select(.comments > 0)] | length' "$dest/issues/issues.json")"
  i=0
  while read -r num; do
    i=$((i + 1))
    st detail "Step: Downloading issue comments ($i of $n)"; st sub $((i * 100 / n))
    api_get_all "$api/issues/$num/comments" > "$dest/issues/comments/$num.json"
  done < <(jq -r '.[] | select(.comments > 0) | .number' "$dest/issues/issues.json")
  echo "  issues: $(jq length "$dest/issues/issues.json")"

  # 4. Pull requests: details, conversation comments, review comments, reviews
  set_step "Downloading pull requests" 25
  mkdir -p "$dest/pulls/conversation" "$dest/pulls/review-comments" "$dest/pulls/reviews"
  api_get_all "$api/pulls" "state=all" > "$dest/pulls/pulls.json"
  n="$(jq length "$dest/pulls/pulls.json")"
  i=0
  while read -r num c rc; do
    i=$((i + 1))
    st detail "Step: Downloading pull request #$num ($i of $n)"; st sub $((i * 100 / n))
    [ "$c" -gt 0 ]  && api_get_all "$api/issues/$num/comments" > "$dest/pulls/conversation/$num.json"
    [ "$rc" -gt 0 ] && api_get_all "$api/pulls/$num/comments"  > "$dest/pulls/review-comments/$num.json"
    api_get_all "$api/pulls/$num/reviews" > "$dest/pulls/reviews/$num.json"
  done < <(jq -r '.[] | "\(.number) \(.comments // 0) \(.review_comments // 0)"' "$dest/pulls/pulls.json")
  echo "  pull requests: $n"

  # 5. Zip into Downloads with a timestamp name
  set_step "Compressing to zip" 8
  watch_end "$(du -sb "$work" 2>/dev/null | cut -f1)"
  ts="$(date +"%Y.%m.%d.%H.%M.%S")"
  out="$OUT_DIR/$ts - $repo.zip"
  if (cd "$work" && zip -qr "$out" "$repo"); then
    echo "  saved: $out"
    mark_done "$repo"
  else
    echo "  ! zip failed"
    mark_fail "$repo"
  fi
  rm -rf "$work"
}

select_repos "Backup repositories"

N_TOTAL=${#SELECTED[@]}
mkdir -p "$OUT_DIR"
START_TS="$(date +%s)"
progress_start "Repository backup"
st n_total "$N_TOTAL"; st pct_total "$((N_TOTAL * 100))"; sync_counts

REPO_IDX=0
for url in "${SELECTED[@]}"; do
  backup_repo "$url"
  REPO_IDX=$((REPO_IDX + 1))
done

summary="Finished in $(human_time $(( $(date +%s) - START_TS )))"$'\n'"Backed up: $N_DONE   Failed: $N_FAIL"
summary+=$'\n'"Total received: $(human_bytes "$(sget base_received)")"
[ -n "$FAILED" ] && summary+=$'\n'"Failed repos: $FAILED"
echo; echo "$summary"
command -v notify-send >/dev/null && notify-send "Repo backup finished" "$N_DONE backed up, $N_FAIL failed"
progress_done "$summary"
exit $(( N_FAIL > 0 ? 1 : 0 ))

#!/usr/bin/env bash
# Downloads selected assets of each chosen repo's latest release into
# ~/Downloads/"<release name>"/
# Opens a console window, a repo selection dialog (nothing ticked by default) and a live progress window.

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

# Only assets whose file name ENDS with one of these are downloaded
# (case-insensitive). Leave the list empty to download every asset.
# Add more lines to also grab e.g. "SHA256SUMS.txt".
ASSET_SUFFIXES=(
  "-linux-x86_64.flatpak"
  "-windows-x64.msi"
  "-linux-x86_64.flatpak.asc"
  "-windows-x64.msi.asc"
)

DEFAULT_CHECKED="FALSE"   # TRUE = all ticked on launch, FALSE = none ticked

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

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

# Returns 0 if the asset name matches one of ASSET_SUFFIXES (or the list is empty)
want_asset() {
  [ "${#ASSET_SUFFIXES[@]}" -eq 0 ] && return 0
  local name="${1,,}" s
  for s in "${ASSET_SUFFIXES[@]}"; do
    [[ "$name" == *"${s,,}" ]] && return 0
  done
  return 1
}

# Remove characters that are not allowed in folder names
sanitize() {
  printf '%s' "$1" | tr -d '/\\:*?"<>|' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

select_repos "Download latest releases"

N_TOTAL=${#SELECTED[@]}
mkdir -p "$OUT_DIR" "$STATE/rel"
START_TS="$(date +%s)"
progress_start "Download latest releases"
st n_total "$N_TOTAL"; sync_counts
st headline "Checking latest releases..."
TOTAL_BYTES=0
FILES_GOT=0

# ---- Phase 1: look up every release and work out what still needs downloading
for i in "${!SELECTED[@]}"; do
  url="${SELECTED[$i]}"
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  st detail "Looking up $owner/$repo ($((i + 1)) of $N_TOTAL)"
  echo "== $owner/$repo"

  # /releases/latest returns the newest published release (not drafts or pre-releases)
  json="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$owner/$repo/releases/latest")" \
    || { echo "  ! no latest release found or API error"; : > "$STATE/rel/$i.err"; continue; }

  name="$(jq -r '.name // empty' <<<"$json")"
  [ -z "$name" ] && name="$(jq -r '.tag_name' <<<"$json")"
  safe="$(sanitize "$name")"; [ -z "$safe" ] && safe="$repo-release"
  folder="$OUT_DIR/$safe"
  printf '%s' "$name"   > "$STATE/rel/$i.name"
  printf '%s' "$folder" > "$STATE/rel/$i.folder"

  : > "$STATE/rel/$i.tsv"
  while IFS=$'\t' read -r f u s; do
    want_asset "$f" || continue
    todo=1
    if [ -f "$folder/$f" ] && [ "$(stat -c %s "$folder/$f")" = "$s" ]; then
      todo=0
    else
      TOTAL_BYTES=$((TOTAL_BYTES + s))
    fi
    printf '%s\t%s\t%s\t%s\n' "$f" "$u" "$s" "$todo" >> "$STATE/rel/$i.tsv"
  done < <(jq -r '.assets[] | "\(.name)\t\(.browser_download_url)\t\(.size)"' <<<"$json")
  echo "  release: $name  (matched $(wc -l < "$STATE/rel/$i.tsv") of $(jq '.assets | length' <<<"$json") assets)"
done

# ---- Phase 2: download
st total_bytes "$TOTAL_BYTES"; st dl_start "$(date +%s)"
echo; echo "To download: $(human_bytes "$TOTAL_BYTES")"
for i in "${!SELECTED[@]}"; do
  url="${SELECTED[$i]}"
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  echo "== $owner/$repo"

  if [ -e "$STATE/rel/$i.err" ]; then mark_fail "$repo"; continue; fi
  name="$(<"$STATE/rel/$i.name")"; folder="$(<"$STATE/rel/$i.folder")"
  st headline "Repository $((i + 1)) of $N_TOTAL: $owner/$repo - $name"

  M="$(wc -l < "$STATE/rel/$i.tsv")"
  if [ "$M" -eq 0 ]; then
    echo "  ! none of the assets matched ASSET_SUFFIXES"
    st detail "No matching files in this release"
    mark_skip; continue
  fi

  mkdir -p "$folder"
  j=0; got=0; fails=0
  while IFS=$'\t' read -r f u s todo; do
    j=$((j + 1))
    if [ "$todo" = 0 ]; then echo "  already have: $f"; continue; fi
    st detail "File $j of $M: $f ($(human_bytes "$s"))"
    echo "  downloading: $f ($(human_bytes "$s"))"
    part="$folder/$f.part"; CURRENT_PART="$part"
    watch_file "$part"
    curl -fL -# ${AUTH[@]+"${AUTH[@]}"} -o "$part" "$u" </dev/null
    rc=$?
    final="$(stat -c %s "$part" 2>/dev/null || echo 0)"
    watch_end "$final"
    if [ "$rc" -eq 0 ] && [ "$final" = "$s" ]; then
      mv -f "$part" "$folder/$f"; got=$((got + 1)); FILES_GOT=$((FILES_GOT + 1))
    else
      echo "  ! failed: $f"; rm -f "$part"; fails=$((fails + 1))
    fi
    CURRENT_PART=""
  done < "$STATE/rel/$i.tsv"

  echo "  -> $folder"
  if   [ "$fails" -gt 0 ]; then mark_fail "$repo"
  elif [ "$got" -eq 0 ];   then mark_skip
  else                          mark_done "$repo"
  fi
done

elapsed=$(( $(date +%s) - START_TS ))
summary="Finished in $(human_time "$elapsed")"$'\n'"Downloaded $FILES_GOT file(s), $(human_bytes "$(sget base_received)")"
summary+=$'\n'"Completed: $N_DONE   Skipped (already up to date / nothing to get): $N_SKIP   Failed: $N_FAIL"
[ -n "$FAILED" ] && summary+=$'\n'"Failed repos: $FAILED"
echo; echo "$summary"
command -v notify-send >/dev/null && notify-send "Release download finished" "$FILES_GOT file(s), $N_FAIL failed"
progress_done "$summary"
exit $(( N_FAIL > 0 ? 1 : 0 ))

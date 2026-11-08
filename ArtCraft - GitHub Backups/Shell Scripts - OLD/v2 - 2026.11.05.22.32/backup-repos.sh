#!/usr/bin/env bash
# Full git mirror + repo metadata + issues + pull requests (with comments and reviews).
# No wiki, no releases. Output: ~/Downloads/"yyyy.MM.dd.hh.mm.ss - repo.zip"
# A selection dialog opens on launch; all repos are ticked by default.
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

OUT_DIR="$HOME/Downloads"
TOKEN_FILE="$HOME/.config/github-token"
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

AUTH=()
GIT_AUTH=()
if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
  GIT_AUTH=(-c "http.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)")
fi

for cmd in git curl jq zip; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

# Shows a checklist dialog (kdialog on KDE, zenity otherwise) and fills SELECTED.
select_repos() {
  local title="$1" u label out
  SELECTED=()
  if command -v kdialog >/dev/null; then
    local state="off"; [ "$DEFAULT_CHECKED" = "TRUE" ] && state="on"
    local args=()
    for u in "${REPOS[@]}"; do
      args+=("$u" "${u#https://github.com/}" "$state")
    done
    out="$(kdialog --title "$title" --separate-output \
      --checklist "Select repositories:" "${args[@]}")" || exit 0
  elif command -v zenity >/dev/null; then
    local args=()
    for u in "${REPOS[@]}"; do
      args+=("$DEFAULT_CHECKED" "$u")
    done
    out="$(zenity --list --checklist --title="$title" --text="Select repositories:" \
      --column="Pick" --column="Repository URL" --print-column=2 --separator=$'\n' \
      --width=650 --height=650 "${args[@]}")" || exit 0
  else
    echo "Install kdialog or zenity for the selection dialog (sudo dnf install zenity)."
    exit 1
  fi
  [ -z "$out" ] && { echo "Nothing selected."; exit 0; }
  mapfile -t SELECTED <<<"$out"
}

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

backup_repo() {
  local url="$1" path owner repo api work dest ts out
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  api="https://api.github.com/repos/$owner/$repo"
  echo "== $owner/$repo"

  work="$(mktemp -d)"
  dest="$work/$repo"
  mkdir -p "$dest"

  # 1. Full git mirror: all branches, tags, and pull request refs
  if ! git ${GIT_AUTH[@]+"${GIT_AUTH[@]}"} clone --mirror --quiet \
       "https://github.com/$owner/$repo.git" "$dest/git-mirror.git"; then
    echo "  ! git clone failed"; rm -rf "$work"; return
  fi

  # 2. Repo metadata (description, topics, settings, etc.)
  curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" "$api" \
    > "$dest/repo.json" || echo "  ! repo metadata failed"

  # 3. Issues. The issues endpoint also returns PRs, so filter them out.
  mkdir -p "$dest/issues/comments"
  api_get_all "$api/issues" "state=all" \
    | jq 'map(select(has("pull_request") | not))' > "$dest/issues/issues.json"
  jq -r '.[] | select(.comments > 0) | .number' "$dest/issues/issues.json" | while read -r n; do
    api_get_all "$api/issues/$n/comments" > "$dest/issues/comments/$n.json"
  done
  echo "  issues: $(jq length "$dest/issues/issues.json")"

  # 4. Pull requests: details, conversation comments, review comments, reviews
  mkdir -p "$dest/pulls/conversation" "$dest/pulls/review-comments" "$dest/pulls/reviews"
  api_get_all "$api/pulls" "state=all" > "$dest/pulls/pulls.json"
  jq -r '.[] | "\(.number) \(.comments) \(.review_comments)"' "$dest/pulls/pulls.json" \
    | while read -r n c rc; do
        [ "$c" -gt 0 ]  && api_get_all "$api/issues/$n/comments" > "$dest/pulls/conversation/$n.json"
        [ "$rc" -gt 0 ] && api_get_all "$api/pulls/$n/comments"  > "$dest/pulls/review-comments/$n.json"
        api_get_all "$api/pulls/$n/reviews" > "$dest/pulls/reviews/$n.json"
      done
  echo "  pull requests: $(jq length "$dest/pulls/pulls.json")"

  # 5. Zip into Downloads with a timestamp name
  ts="$(date +"%Y.%m.%d.%H.%M.%S")"
  out="$OUT_DIR/$ts - $repo.zip"
  if (cd "$work" && zip -qr "$out" "$repo"); then
    echo "  saved: $out"
  else
    echo "  ! zip failed"
  fi
  rm -rf "$work"
}

select_repos "Backup repositories"

mkdir -p "$OUT_DIR"
for url in "${SELECTED[@]}"; do
  backup_repo "$url"
done
echo "Done."
command -v notify-send >/dev/null && notify-send "Repo backup finished" "${#SELECTED[@]} repo(s) processed"

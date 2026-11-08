#!/usr/bin/env bash
# Downloads the attached files of each repo's latest release into
# ~/Downloads/"<release name>"/
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

OUT_DIR="$HOME/Downloads"
TOKEN_FILE="$HOME/.config/github-token"
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

AUTH=()
if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
fi

command -v jq >/dev/null || { echo "Missing dependency: jq"; exit 1; }

# Remove characters that are not allowed in folder names
sanitize() {
  printf '%s' "$1" | tr -d '/\\:*?"<>|' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

mkdir -p "$OUT_DIR"
for url in "${REPOS[@]}"; do
  path="${url#https://github.com/}"; path="${path%/}"; path="${path%.git}"
  owner="${path%%/*}"; repo="${path#*/}"
  echo "== $owner/$repo"

  # /releases/latest returns the newest published release (not drafts or pre-releases)
  json="$(curl -fsSL ${AUTH[@]+"${AUTH[@]}"} -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$owner/$repo/releases/latest")" \
    || { echo "  ! no latest release found or API error"; continue; }

  name="$(jq -r '.name // empty' <<<"$json")"
  [ -z "$name" ] && name="$(jq -r '.tag_name' <<<"$json")"
  folder="$OUT_DIR/$(sanitize "$name")"
  mkdir -p "$folder"
  echo "  release: $name"
  echo "  folder:  $folder"

  count="$(jq '.assets | length' <<<"$json")"
  if [ "$count" -eq 0 ]; then
    echo "  no attached files in this release"
    continue
  fi

  jq -r '.assets[] | "\(.name)\t\(.browser_download_url)"' <<<"$json" \
    | while IFS=$'\t' read -r file dl; do
        echo "  downloading: $file"
        curl -fL ${AUTH[@]+"${AUTH[@]}"} -o "$folder/$file" "$dl" \
          || echo "  ! failed: $file"
      done
done
echo "Done."

#!/usr/bin/env bash
# Downloads selected assets of each chosen repo's latest release into
# ~/Downloads/"<release name>"/
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

# Only assets whose file name ENDS with one of these are downloaded
# (case-insensitive). Leave the list empty to download every asset.
# Add more lines to also grab e.g. "-linux-x86_64.flatpak.asc" or "SHA256SUMS.txt".
ASSET_SUFFIXES=(
  "-linux-x86_64.flatpak"
  "-windows-x64.msi"
)

DEFAULT_CHECKED="TRUE"    # TRUE = all ticked on launch, FALSE = none ticked

OUT_DIR="$HOME/Downloads"
TOKEN_FILE="$HOME/.config/github-token"
TOKEN="${GITHUB_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"

AUTH=()
if [ -n "$TOKEN" ]; then
  AUTH=(-H "Authorization: Bearer $TOKEN")
fi

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

# Shows a checklist dialog (kdialog on KDE, zenity otherwise) and fills SELECTED.
select_repos() {
  local title="$1" u out
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

mkdir -p "$OUT_DIR"
for url in "${SELECTED[@]}"; do
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
  echo "  release: $name"

  total="$(jq '.assets | length' <<<"$json")"
  if [ "$total" -eq 0 ]; then
    echo "  no attached files in this release"
    continue
  fi

  got=0
  while IFS=$'\t' read -r file dl; do
    want_asset "$file" || continue
    mkdir -p "$folder"
    got=$((got + 1))
    if [ -s "$folder/$file" ]; then
      echo "  already exists, skipping: $file"
      continue
    fi
    echo "  downloading: $file"
    curl -fL ${AUTH[@]+"${AUTH[@]}"} -o "$folder/$file" "$dl" \
      || { echo "  ! failed: $file"; rm -f "$folder/$file"; }
  done < <(jq -r '.assets[] | "\(.name)\t\(.browser_download_url)"' <<<"$json")

  if [ "$got" -eq 0 ]; then
    echo "  ! none of the $total assets matched ASSET_SUFFIXES"
  else
    echo "  matched $got of $total assets -> $folder"
  fi
done
echo "Done."
command -v notify-send >/dev/null && notify-send "Release download finished" "${#SELECTED[@]} repo(s) processed"

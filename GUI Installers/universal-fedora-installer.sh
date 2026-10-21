#!/usr/bin/env bash
# Universal GUI installer for Fedora (zenity).
#
# From a file:  .rpm  .flatpak  .flatpakref  .AppImage  .snap  .whl  .deb (via alien)
#               .tar.gz/.tgz/.tar.xz/.tar.bz2/.tar.zst/.zip (extracted to /opt/<name>)
#               .run (vendor installer scripts)
# By name:      dnf, Flathub, PyPI (pip --user), Cargo (crates.io), npm (to ~/.local), Nix, COPR repos
#
# Flow: choose source -> pick file / enter name -> sudo password (only if needed) -> progress -> result

set -u
shopt -s nocasematch
TITLE="Fedora Installer"
PASS=""
NEEDS_ROOT=1
KIND=""
LABEL=""
NOTE=""
PREREQ=""
INSTALL_FN=""
FUSE_MISSING=0
COPR=""
NAMES=()

die()     { zenity --error --title="$TITLE" --text="$1" --width=420; exit 1; }
confirm() { zenity --question --title="$TITLE" --text="$1" --width=440 --ok-label="Continue" --cancel-label="Cancel"; }
as_root() { printf '%s\n' "$PASS" | sudo -S -p '' "$@"; }

command -v zenity >/dev/null 2>&1 || { echo "zenity not found. Install with: sudo dnf install zenity" >&2; exit 1; }

# Ask for one or more names, validate each against a regex.  ask_names <prompt> <regex> <what>
ask_names() {
    local input n
    input=$(zenity --entry --title="$TITLE" --text="$1" --width=440) || exit 0
    read -ra NAMES <<< "$input"
    [[ ${#NAMES[@]} -gt 0 ]] || exit 0
    for n in "${NAMES[@]}"; do
        [[ "$n" =~ $2 ]] || die "Invalid $3: $n"
    done
    LABEL="${NAMES[*]}"
}

need_flatpak() { command -v flatpak >/dev/null || die "flatpak is not installed.\nInstall with: sudo dnf install flatpak"; }
need_pip()     { command -v python3 >/dev/null || PREREQ+=" python3"; python3 -m pip --version >/dev/null 2>&1 || PREREQ+=" python3-pip"; }

# ---------------------------------------------------------------- installers
# Each runs inside the progress pipeline; lines starting with "# " update the progress text.

run_prereq() {
    [[ -z "${PREREQ// /}" ]] && return 0
    echo "# Installing prerequisites:$PREREQ..."
    # shellcheck disable=SC2086
    as_root dnf install -y $PREREQ
}

inst_rpm()        { as_root dnf install -y "$PKG"; }
inst_pkgname()    { as_root dnf install -y "${NAMES[@]}"; }
inst_flatpakref() { as_root flatpak install --system -y --noninteractive --from "$PKG"; }
inst_flatpak()    { as_root flatpak install --system -y --noninteractive --bundle "$PKG"; }
inst_run()        { as_root sh "$PKG"; }

inst_snap() {
    as_root snap install --dangerous "$PKG" || {
        echo "# Retrying with classic confinement..."
        as_root snap install --dangerous --classic "$PKG"
    }
}

inst_flathub() {
    echo "# Ensuring Flathub remote is configured..."
    as_root flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
    as_root flatpak install --system -y --noninteractive flathub "${NAMES[@]}"
}

inst_pip_file() { run_prereq || return 1; python3 -m pip install --user "$PKG"; }
inst_pip_name() { run_prereq || return 1; python3 -m pip install --user "${NAMES[@]}"; }
inst_cargo()    { run_prereq || return 1; cargo install --locked "${NAMES[@]}"; }
inst_npm()      { run_prereq || return 1; npm install -g --prefix "$HOME/.local" "${NAMES[@]}"; }

inst_nix() {
    local args=() n
    for n in "${NAMES[@]}"; do args+=("nixpkgs#$n"); done
    nix --extra-experimental-features 'nix-command flakes' profile install "${args[@]}" ||
        nix --extra-experimental-features 'nix-command flakes' profile add "${args[@]}"
}

inst_copr() {
    run_prereq || return 1
    echo "# Enabling COPR repository $COPR..."
    as_root dnf copr enable -y "$COPR" || return 1
    if [[ ${#NAMES[@]} -gt 0 ]]; then
        echo "# Installing ${NAMES[*]}..."
        as_root dnf install -y "${NAMES[@]}"
    fi
}

inst_appimage() {
    if [[ $FUSE_MISSING -eq 1 ]]; then
        echo "# Installing fuse-libs (required by AppImages)..."
        as_root dnf install -y fuse-libs || return 1
    fi
    local app dest="$HOME/Applications" desk="$HOME/.local/share/applications"
    app=$(basename "$PKG"); app=${app%.*}
    mkdir -p "$dest" "$desk" || return 1
    echo "# Copying to $dest..."
    cp -f "$PKG" "$dest/$(basename "$PKG")" && chmod +x "$dest/$(basename "$PKG")" || return 1
    cat > "$desk/appimage-$app.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$app
Exec="$dest/$(basename "$PKG")" %U
Terminal=false
Categories=Utility;
EOF
    update-desktop-database "$desk" >/dev/null 2>&1
    echo "Installed to $dest/$(basename "$PKG") with a menu entry."
}

inst_archive() {
    local app tmp entries src
    app=$(basename "$PKG")
    app=${app%.tar.*}; app=${app%.tgz}; app=${app%.zip}
    local dest="/opt/$app"
    [[ -e "$dest" ]] && { echo "ERROR: $dest already exists. Remove it first or rename the archive."; return 1; }

    tmp=$(mktemp -d)
    echo "# Extracting archive..."
    if [[ "$PKG" == *.zip ]]; then
        command -v unzip >/dev/null 2>&1 || as_root dnf install -y unzip || return 1
        unzip -q "$PKG" -d "$tmp" || { rm -rf "$tmp"; return 1; }
    else
        tar -xf "$PKG" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    fi

    src="$tmp"
    entries=$(find "$tmp" -mindepth 1 -maxdepth 1 | wc -l)
    [[ $entries -eq 1 && -d "$(find "$tmp" -mindepth 1 -maxdepth 1)" ]] && src=$(find "$tmp" -mindepth 1 -maxdepth 1)

    echo "# Installing to $dest..."
    as_root mkdir -p "$dest" && as_root cp -a "$src"/. "$dest"/ && as_root chown -R root:root "$dest" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    echo "Extracted to $dest (no menu entry or PATH link was created)."
}

inst_deb() {
    local tmp rc
    command -v alien >/dev/null 2>&1 || { echo "# Installing alien..."; as_root dnf install -y alien || return 1; }
    tmp=$(mktemp -d)
    cp "$PKG" "$tmp/" || return 1
    echo "# Converting .deb to .rpm (maintainer scripts are NOT carried over)..."
    ( cd "$tmp" && as_root alien --to-rpm --keep-version "$(basename "$PKG")" ) || { as_root rm -rf "$tmp"; return 1; }
    echo "# Installing converted package..."
    as_root sh -c "dnf install -y '$tmp'/*.rpm"
    rc=$?
    as_root rm -rf "$tmp"
    return $rc
}

# ---------------------------------------------------------------- source select
MODE=$(zenity --list --title="$TITLE" --text="What do you want to install?" \
    --column="Source" \
    "Local file" \
    "Package name (dnf)" \
    "Flatpak app ID (Flathub)" \
    "Python package (PyPI)" \
    "Cargo crate (crates.io)" \
    "npm package" \
    "Nix package (nixpkgs)" \
    "COPR repository" \
    --width=400 --height=380 --hide-header) || exit 0

case "$MODE" in
"Local file")
    PKG=$(zenity --file-selection --title="$TITLE - Select a package" \
        --filename="$HOME/Downloads/" \
        --file-filter="All supported | *.rpm *.flatpak *.flatpakref *.AppImage *.snap *.whl *.deb *.tar.* *.tgz *.zip *.run" \
        --file-filter="RPM | *.rpm" \
        --file-filter="Flatpak | *.flatpak *.flatpakref" \
        --file-filter="AppImage | *.AppImage" \
        --file-filter="Python wheel | *.whl" \
        --file-filter="Archives | *.tar.* *.tgz *.zip" \
        --file-filter="Other | *.snap *.deb *.run" \
        --file-filter="All files | *") || exit 0
    [[ -f "$PKG" ]] || die "File not found:\n$PKG"
    LABEL=$(basename "$PKG")

    case "$PKG" in
    *.rpm)        KIND="RPM";         INSTALL_FN=inst_rpm ;;
    *.flatpakref) KIND="Flatpak ref"; INSTALL_FN=inst_flatpakref; need_flatpak ;;
    *.flatpak)    KIND="Flatpak";     INSTALL_FN=inst_flatpak;    need_flatpak ;;
    *.appimage)   KIND="AppImage";    INSTALL_FN=inst_appimage
                  if ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then NEEDS_ROOT=0; else FUSE_MISSING=1; fi ;;
    *.whl)        KIND="Python wheel"; INSTALL_FN=inst_pip_file; NEEDS_ROOT=0; need_pip
                  NOTE="Installed for your user (scripts go to ~/.local/bin)." ;;
    *.snap)       KIND="Snap";        INSTALL_FN=inst_snap
                  command -v snap >/dev/null || die "snapd is not installed (not default on Fedora).\nInstall with: sudo dnf install snapd, then reboot and run: sudo ln -s /var/lib/snapd/snap /snap"
                  confirm "This installs a LOCAL snap with --dangerous (no store signature verification).\n\n$LABEL" || exit 0 ;;
    *.deb)        KIND="DEB";         INSTALL_FN=inst_deb
                  confirm "WARNING: .deb packages are built for Debian-based distros (Debian, Ubuntu, Mint, etc.), not Fedora.\n\nThey are converted with alien, which is unreliable: install scripts are dropped and dependencies often don't map to Fedora packages. Prefer an RPM, Flatpak or AppImage build if one exists.\n\n$LABEL" || exit 0 ;;
    *.tar.*|*.tgz|*.zip)
                  KIND="Archive";     INSTALL_FN=inst_archive ;;
    *.run)        KIND="Installer script"; INSTALL_FN=inst_run
                  confirm "This runs $LABEL as ROOT. Only continue if you trust its source.\n\nIt may fail if it needs an interactive terminal." || exit 0 ;;
    *)            die "Unsupported file type:\n$PKG" ;;
    esac
    ;;

"Package name (dnf)")
    ask_names "Package name(s), space-separated:" '^[A-Za-z0-9][A-Za-z0-9._+@*-]*$' "package name"
    KIND="dnf"; INSTALL_FN=inst_pkgname
    ;;

"Flatpak app ID (Flathub)")
    need_flatpak
    ask_names "Flathub app ID(s) (e.g. org.mozilla.firefox):" '^[A-Za-z0-9][A-Za-z0-9._-]*$' "app ID"
    KIND="Flathub"; INSTALL_FN=inst_flathub
    ;;

"Python package (PyPI)")
    ask_names "PyPI package(s) (optional pin: name==1.2.3):" '^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9,_-]+\])?(==[A-Za-z0-9.*+!_-]+)?$' "package"
    KIND="PyPI"; INSTALL_FN=inst_pip_name; NEEDS_ROOT=0; need_pip
    NOTE="Installed for your user (scripts go to ~/.local/bin)."
    ;;

"Cargo crate (crates.io)")
    ask_names "Crate name(s):" '^[A-Za-z0-9_-]+$' "crate name"
    KIND="Cargo"; INSTALL_FN=inst_cargo; NEEDS_ROOT=0
    command -v cargo >/dev/null || PREREQ+=" cargo"
    command -v cc >/dev/null    || PREREQ+=" gcc"
    NOTE="Binaries are in ~/.cargo/bin (add it to PATH if needed). Crates compile from source, which can take a while."
    ;;

"npm package")
    ask_names "npm package(s) (e.g. typescript or @scope/name@1.2.3):" '^(@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*(@[A-Za-z0-9._-]+)?$' "npm package"
    KIND="npm"; INSTALL_FN=inst_npm; NEEDS_ROOT=0
    command -v npm >/dev/null || PREREQ+=" nodejs-npm"
    NOTE="Installed globally for your user under ~/.local (binaries in ~/.local/bin)."
    ;;

"Nix package (nixpkgs)")
    command -v nix >/dev/null || die "Nix is not installed.\nInstall Nix first (see https://nixos.org/download), then run this again."
    ask_names "nixpkgs attribute name(s) (e.g. hello, ripgrep):" '^[A-Za-z0-9][A-Za-z0-9._+-]*$' "Nix attribute"
    KIND="Nix"; INSTALL_FN=inst_nix; NEEDS_ROOT=0
    NOTE="Installed into your Nix profile (~/.nix-profile/bin)."
    ;;

"COPR repository")
    confirm "COPR repositories are community-built and NOT vetted by the Fedora Project. Enabling one lets it supply and update packages on your system.\n\nOnly continue if you trust the maintainer." || exit 0
    COPR=$(zenity --entry --title="$TITLE" --text="COPR repository (owner/project):" --width=440) || exit 0
    [[ "$COPR" =~ ^@?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "Invalid COPR name: $COPR\nExpected format: owner/project"
    INPUT=$(zenity --entry --title="$TITLE" --text="Package(s) to install from it (space-separated).\nLeave empty to only enable the repo:" --width=440) || exit 0
    read -ra NAMES <<< "$INPUT"
    for n in "${NAMES[@]}"; do
        [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._+@-]*$ ]] || die "Invalid package name: $n"
    done
    KIND="COPR"; LABEL="$COPR${NAMES[*]:+ ($INPUT)}"; INSTALL_FN=inst_copr
    dnf copr --help >/dev/null 2>&1 || { rpm -q dnf5 >/dev/null 2>&1 && PREREQ+=" dnf5-plugins" || PREREQ+=" dnf-plugins-core"; }
    ;;
*) exit 0 ;;
esac

[[ -n "${PREREQ// /}" ]] && NEEDS_ROOT=1

# ---------------------------------------------------------------- auth
if [[ $NEEDS_ROOT -eq 1 ]]; then
    PASS=$(zenity --password --title="$TITLE - Authentication required") || exit 0
    if ! printf '%s\n' "$PASS" | sudo -S -p '' -v 2>/dev/null; then
        PASS=""
        die "Authentication failed. Wrong password or no sudo rights."
    fi
fi

# ---------------------------------------------------------------- run
LOG=$(mktemp /tmp/fedora-install.XXXXXX.log)
STATUS_FILE=$(mktemp)

{
    echo "# Installing $LABEL ($KIND)..."
    "$INSTALL_FN" 2>&1 | while IFS= read -r line; do
        echo "$line" >> "$LOG"
        clean=${line##*$'\r'}
        [[ -n "${clean// /}" ]] && { [[ "$clean" == "# "* ]] && echo "$clean" || echo "# ${clean:0:100}"; }
    done
    echo "${PIPESTATUS[0]}" > "$STATUS_FILE"
} | zenity --progress --pulsate --auto-close --no-cancel \
    --title="$TITLE" --text="Starting..." --width=500

PASS=""
sudo -k 2>/dev/null

# ---------------------------------------------------------------- result
RC=$(cat "$STATUS_FILE" 2>/dev/null || echo 1)
rm -f "$STATUS_FILE"

if [[ "$RC" == "0" ]]; then
    zenity --info --title="$TITLE" --text="Install successful:\n$LABEL${NOTE:+\n\n$NOTE}" --width=420
    rm -f "$LOG"
else
    zenity --text-info --title="$TITLE - Install failed (exit code $RC)" \
        --filename="$LOG" --width=700 --height=450
    exit 1
fi

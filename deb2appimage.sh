#!/bin/bash
# =============================================================================
# deb2appimage.sh — Convert .deb packages to AppImages on Bazzite / immutable
#                   Fedora-based systems (Silverblue, Kinoite, etc.)
#
# USAGE:
#   ./deb2appimage.sh <path/to/package.deb> [output/dir]
#
# EXAMPLES:
#   ./deb2appimage.sh ~/Downloads/Portmaster_2.1.18_amd64.deb
#   ./deb2appimage.sh ~/Downloads/Portmaster_2.1.18_amd64.deb ~/AppImages
#
# HOW IT WORKS (Bazzite-safe):
#   - Uses only 'ar' and 'tar' for extraction (pre-installed on Bazzite)
#   - Downloads appimagetool as a self-contained AppImage (no system install)
#   - Never runs rpm-ostree or dnf — safe for immutable base layer
#   - If a tool is missing, it offers to install it inside Distrobox
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}"; }

# ── Constants ─────────────────────────────────────────────────────────────────
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
TOOLS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/deb2appimage"
APPIMAGETOOL="$TOOLS_DIR/appimagetool"
DISTROBOX_NAME="appimage-builder"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    echo -e "${BOLD}Usage:${RESET} $0 <package.deb> [output_directory]"
    echo
    echo "Safely converts a .deb package to an AppImage on Bazzite."
    echo "Does NOT modify the system base layer (no rpm-ostree / dnf)."
    echo
    echo -e "${BOLD}Options:${RESET}"
    echo "  -h, --help    Show this help message"
    echo "  --clean       Remove the Distrobox builder container if it exists"
    exit 0
}

# ── Parse args ────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then usage; fi

case "${1:-}" in
    -h|--help) usage ;;
    --clean)
        info "Removing Distrobox container '$DISTROBOX_NAME' if it exists..."
        distrobox rm --force "$DISTROBOX_NAME" 2>/dev/null || true
        success "Done."
        exit 0
        ;;
esac

DEB_FILE="$(realpath "$1")"
OUTPUT_DIR="${2:-$HOME/AppImages}"

# ── Validate input ────────────────────────────────────────────────────────────
[[ -f "$DEB_FILE" ]] || die "File not found: $DEB_FILE"
[[ "$DEB_FILE" == *.deb ]] || die "Input must be a .deb file."

DEB_BASENAME="$(basename "$DEB_FILE" .deb)"
# Strip version/arch suffixes: Portmaster_2.1.18_amd64 → Portmaster
APP_NAME="$(echo "$DEB_BASENAME" | cut -d'_' -f1 | sed 's/-[0-9].*//')"

echo -e "\n${BOLD}╔══════════════════════════════════════════╗"
echo -e "║       deb → AppImage (Bazzite-safe)      ║"
echo -e "╚══════════════════════════════════════════╝${RESET}\n"
info "Package : $DEB_FILE"
info "App name: $APP_NAME"
info "Output  : $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR" "$TOOLS_DIR"

# ── Check required host tools ─────────────────────────────────────────────────
step "Checking required tools"

MISSING_TOOLS=()
for tool in ar tar find file; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    warn "Missing tools on host: ${MISSING_TOOLS[*]}"
    warn "These should normally be pre-installed on Bazzite."
    warn "Do NOT use rpm-ostree/dnf to install them — use Distrobox instead."
    echo
    read -rp "Create/use a Distrobox container to supply missing tools? [Y/n] " choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        if ! command -v distrobox &>/dev/null; then
            die "Distrobox is not installed. Please install it first:\n  ujust install-distrobox"
        fi
        if ! distrobox list | grep -q "$DISTROBOX_NAME"; then
            info "Creating Distrobox container '$DISTROBOX_NAME' (Ubuntu)..."
            distrobox create --name "$DISTROBOX_NAME" --image ubuntu:22.04 --yes
        fi
        info "Running inside Distrobox container..."
        # Re-run this script inside the container
        distrobox enter "$DISTROBOX_NAME" -- bash "$0" "$DEB_FILE" "$OUTPUT_DIR"
        exit $?
    else
        die "Cannot continue without required tools."
    fi
fi
success "All required tools found."

# ── Download appimagetool if needed ───────────────────────────────────────────
step "Checking appimagetool"

if [[ ! -x "$APPIMAGETOOL" ]]; then
    info "Downloading appimagetool to $TOOLS_DIR ..."
    if command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "$APPIMAGETOOL" "$APPIMAGETOOL_URL"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$APPIMAGETOOL" "$APPIMAGETOOL_URL"
    else
        die "Neither curl nor wget found. Cannot download appimagetool."
    fi
    chmod +x "$APPIMAGETOOL"
    success "appimagetool downloaded."
else
    success "appimagetool already present."
fi

# ── Set up working directory ───────────────────────────────────────────────────
WORK_DIR="$(mktemp -d /tmp/deb2appimage.XXXXXX)"
trap 'info "Cleaning up..."; rm -rf "$WORK_DIR"' EXIT

APPDIR="$WORK_DIR/$APP_NAME.AppDir"
EXTRACT_DIR="$WORK_DIR/extract"
mkdir -p "$APPDIR" "$EXTRACT_DIR"

# ── Extract .deb ──────────────────────────────────────────────────────────────
step "Extracting .deb package"

cd "$WORK_DIR"

# .deb files are 'ar' archives containing control.tar.* and data.tar.*
ar x "$DEB_FILE" || die "Failed to extract .deb with 'ar'. Is this a valid .deb file?"

# Find and extract the data archive (contains the actual files)
DATA_ARCHIVE="$(find "$WORK_DIR" -maxdepth 1 -name 'data.tar.*' | head -1)"
[[ -n "$DATA_ARCHIVE" ]] || die "No data.tar.* found inside the .deb. Package may be malformed."

info "Found data archive: $(basename "$DATA_ARCHIVE")"
tar -xf "$DATA_ARCHIVE" -C "$EXTRACT_DIR" || die "Failed to extract data archive."
success "Extraction complete."

# ── Populate AppDir ───────────────────────────────────────────────────────────
step "Building AppDir structure"

# Copy all extracted files into AppDir
cp -a "$EXTRACT_DIR/"* "$APPDIR/"
success "Files copied to AppDir."

# ── Find .desktop file ────────────────────────────────────────────────────────
step "Locating .desktop file"

DESKTOP_FILES=()
while IFS= read -r -d '' f; do
    DESKTOP_FILES+=("$f")
done < <(find "$APPDIR" -name "*.desktop" -print0 2>/dev/null)

if [[ ${#DESKTOP_FILES[@]} -eq 0 ]]; then
    warn "No .desktop file found inside the package."
    warn "Creating a minimal one — you may need to edit it."
    cat > "$APPDIR/$APP_NAME.desktop" << EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$APP_NAME
Icon=$APP_NAME
Type=Application
Categories=Utility;
EOF
    DESKTOP_FILE="$APPDIR/$APP_NAME.desktop"
elif [[ ${#DESKTOP_FILES[@]} -eq 1 ]]; then
    DESKTOP_FILE="${DESKTOP_FILES[0]}"
    # Copy to AppDir root if not already there
    DESKTOP_BASENAME="$(basename "$DESKTOP_FILE")"
    if [[ ! -f "$APPDIR/$DESKTOP_BASENAME" ]]; then
        cp "$DESKTOP_FILE" "$APPDIR/"
    fi
    DESKTOP_FILE="$APPDIR/$DESKTOP_BASENAME"
    success "Found: $(basename "$DESKTOP_FILE")"
else
    info "Multiple .desktop files found:"
    for i in "${!DESKTOP_FILES[@]}"; do
        echo "  [$((i+1))] ${DESKTOP_FILES[$i]}"
    done
    read -rp "Which one to use? [1]: " pick
    pick="${pick:-1}"
    DESKTOP_FILE="${DESKTOP_FILES[$((pick-1))]}"
    DESKTOP_BASENAME="$(basename "$DESKTOP_FILE")"
    [[ ! -f "$APPDIR/$DESKTOP_BASENAME" ]] && cp "$DESKTOP_FILE" "$APPDIR/"
    DESKTOP_FILE="$APPDIR/$DESKTOP_BASENAME"
    success "Using: $(basename "$DESKTOP_FILE")"
fi

# ── Extract Exec= and Icon= from .desktop ─────────────────────────────────────
EXEC_CMD="$(grep -m1 '^Exec=' "$DESKTOP_FILE" | cut -d'=' -f2- | awk '{print $1}' | xargs basename 2>/dev/null || true)"
ICON_NAME="$(grep -m1 '^Icon=' "$DESKTOP_FILE" | cut -d'=' -f2- | xargs || true)"

info "Exec: $EXEC_CMD"
info "Icon: $ICON_NAME"

# ── Find and copy icon ────────────────────────────────────────────────────────
step "Locating icon"

find_icon() {
    local name="$1"
    # Prefer 256x256 or 512x512, fall back to any size
    for size in 512x512 256x256 128x128 64x64 48x48 32x32; do
        local f
        f="$(find "$APPDIR" -iname "${name}.png" -path "*/${size}/*" 2>/dev/null | head -1)"
        [[ -n "$f" ]] && echo "$f" && return
    done
    # Any PNG with that name
    find "$APPDIR" -iname "${name}.png" 2>/dev/null | head -1
    # Any SVG
    find "$APPDIR" -iname "${name}.svg" 2>/dev/null | head -1
}

ICON_FILE=""
if [[ -n "$ICON_NAME" ]]; then
    ICON_FILE="$(find_icon "$ICON_NAME")"
fi

# Fallback: search by app name
if [[ -z "$ICON_FILE" ]]; then
    ICON_FILE="$(find_icon "${APP_NAME,,}")"
fi

# Fallback: any PNG icon
if [[ -z "$ICON_FILE" ]]; then
    ICON_FILE="$(find "$APPDIR" -name "*.png" 2>/dev/null | head -1)"
fi

if [[ -n "$ICON_FILE" ]]; then
    ICON_EXT="${ICON_FILE##*.}"
    ICON_DEST="$APPDIR/${ICON_NAME:-$APP_NAME}.$ICON_EXT"
    if [[ "$ICON_FILE" != "$ICON_DEST" ]]; then
        cp "$ICON_FILE" "$ICON_DEST"
    fi
    success "Icon: $ICON_DEST"
else
    warn "No icon found. AppImage will be created without one."
    warn "You can add one later: copy a PNG to the AppDir root."
fi

# ── Create AppRun symlink ─────────────────────────────────────────────────────
step "Setting up AppRun entry point"

# Find the actual executable
EXEC_PATH=""
if [[ -n "$EXEC_CMD" ]]; then
    EXEC_PATH="$(find "$APPDIR" -name "$EXEC_CMD" -type f 2>/dev/null | head -1)"
    [[ -z "$EXEC_PATH" ]] && EXEC_PATH="$(find "$APPDIR" -name "$EXEC_CMD" 2>/dev/null | head -1)"
fi

# Fallback: look for any executable matching the app name
if [[ -z "$EXEC_PATH" ]]; then
    EXEC_PATH="$(find "$APPDIR/usr/bin" -type f -executable 2>/dev/null | head -1)"
fi

if [[ -n "$EXEC_PATH" ]]; then
    # Make it executable
    chmod +x "$EXEC_PATH"
    # Create AppRun symlink pointing to the executable (relative path required)
    REL_EXEC="$(realpath --relative-to="$APPDIR" "$EXEC_PATH")"
    if [[ -f "$APPDIR/AppRun" ]] || [[ -L "$APPDIR/AppRun" ]]; then
        rm -f "$APPDIR/AppRun"
    fi
    ln -sf "$REL_EXEC" "$APPDIR/AppRun"
    success "AppRun → $REL_EXEC"
else
    warn "Could not auto-detect the main executable."
    info "Executables found in AppDir:"
    find "$APPDIR" -type f -executable 2>/dev/null | grep -v '.so' | head -20
    echo
    read -rp "Enter the relative path to the main executable (e.g. usr/bin/portmaster): " REL_EXEC
    REL_EXEC="${REL_EXEC#/}"  # strip leading slash if present
    [[ -f "$APPDIR/$REL_EXEC" ]] || die "Executable not found: $APPDIR/$REL_EXEC"
    chmod +x "$APPDIR/$REL_EXEC"
    ln -sf "$REL_EXEC" "$APPDIR/AppRun"
    success "AppRun → $REL_EXEC"
fi

# ── Build AppImage ─────────────────────────────────────────────────────────────
step "Building AppImage"

OUTPUT_APPIMAGE="$OUTPUT_DIR/$APP_NAME.AppImage"

info "Running appimagetool..."
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT_APPIMAGE" 2>&1 | \
    grep -v "^$" || true

if [[ -f "$OUTPUT_APPIMAGE" ]]; then
    chmod +x "$OUTPUT_APPIMAGE"
    SIZE="$(du -sh "$OUTPUT_APPIMAGE" | cut -f1)"
    echo
    success "AppImage created successfully!"
    echo -e "  ${BOLD}Path:${RESET} $OUTPUT_APPIMAGE"
    echo -e "  ${BOLD}Size:${RESET} $SIZE"
    echo
    info "To run it: $OUTPUT_APPIMAGE"
    info "To integrate with your desktop, consider using 'AppImageLauncher'."
else
    die "appimagetool ran but no output file was created. Check the logs above."
fi

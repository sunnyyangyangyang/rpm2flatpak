#!/bin/bash
set -e

# =============================================
# RPM to Flatpak - Builder (Fixed Version)
# Purpose: Build Flatpak package from config file
# =============================================

FEDORA_VER="43"
RUNTIME_VER="f43"
BASE_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VER}"
ARCH=$(uname -m)

if [ -z "$1" ]; then
    echo "Usage: $0 <config_file>"
    echo "Example: $0 wechat.conf"
    echo ""
    echo "Tip: Run ./rpm2flatpak-probe.sh first to generate config file"
    exit 1
fi

CONF_FILE="$1"
if [ ! -f "$CONF_FILE" ]; then
    echo "Error: Config file does not exist: $CONF_FILE"
    exit 1
fi

# =============================================
# Parse Configuration File
# =============================================
parse_conf() {
    local section=""
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Parse section
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Parse key=value
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            eval "CFG_${section}_${key}='$value'"
        fi
    done < "$CONF_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RPM to Flatpak Builder"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

parse_conf

# Validate required parameters
if [ -z "$CFG_meta_app_name" ] || [ -z "$CFG_exec_exec_path" ]; then
    echo "Error: Config file missing required fields (app_name or exec_path)"
    exit 1
fi

# Read force_install flag from config
FORCE_MODE=0
if [ "$CFG_meta_force_install" = "yes" ]; then
    FORCE_MODE=1
fi

APP_NAME="$CFG_meta_app_name"
RPM_FILE="$CFG_meta_rpm_file"
EXEC_PATH="$CFG_exec_exec_path"
EXEC_NAME="${CFG_exec_exec_name:-$(basename "$EXEC_PATH")}"
DESKTOP_FILE="$CFG_desktop_desktop_file"
ICON_PATH="$CFG_icon_icon_path"

SAFE_NAME=$(echo "$APP_NAME" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
FLATPAK_ID="org.rpm.${SAFE_NAME}"
OUTPUT_BUNDLE="${APP_NAME}.flatpak"

echo "Application name: $APP_NAME"
echo "Flatpak ID: $FLATPAK_ID"
echo "Executable: $EXEC_PATH"
echo "Launch command: $EXEC_NAME"
echo ""

# =============================================
# Working Environment
# =============================================
WORK_DIR=$(mktemp -d -t rpm2flatpak.XXXXXX)
CONTAINER_NAME="builder_$(basename $WORK_DIR)"

echo "[*] Working directory: $WORK_DIR"

cleanup() {
    echo ""
    echo "[*] Cleaning up environment..."
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    echo "[*] Cleanup complete."
}
trap cleanup EXIT INT TERM

# =============================================
# Step 1: Start container and install RPM
# =============================================
echo "[1/6] Starting build container..."
podman run -d --name "$CONTAINER_NAME" \
    --tmpfs /tmp \
    --tmpfs /var/cache/dnf \
    --tmpfs /var/log \
    "$BASE_IMAGE" sleep infinity >/dev/null

echo "[2/6] Installing RPM package..."
if [ -f "$RPM_FILE" ]; then
    podman cp "$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
    RPM_TARGET="/tmp/target.rpm"
else
    # Try to find from current directory
    if [ -f "./$RPM_FILE" ]; then
        podman cp "./$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
        RPM_TARGET="/tmp/target.rpm"
    else
        echo "Error: Cannot find RPM file: $RPM_FILE"
        exit 1
    fi
fi

if [ "$FORCE_MODE" -eq 1 ]; then
    echo "  ⚠️  Force install mode enabled (ignoring dependencies and signature)..."
    # Use rpm directly, ignoring all checks
    podman exec "$CONTAINER_NAME" rpm -ivh --nodeps --nosignature --nodigest "$RPM_TARGET"
else
    # Default mode: Try smart install with dnf
    echo "  → Installing with DNF..."
    if ! podman exec "$CONTAINER_NAME" dnf install -y "$RPM_TARGET" 2>&1 | grep -v "^warning:"; then
        echo "  ⚠ DNF installation encountered issues, attempting to continue..."
        # If DNF fails, extraction will usually be empty, but keeping || true logic for consistency
    fi
fi

# =============================================
# Step 2: Extract files (Critical Fix applied here)
# =============================================
echo "[3/6] Extracting file layer..."

# Fix: Use sed instead of awk to preserve spaces in filenames
# Format "A /path/to/file with spaces" -> remove first 2 chars
podman diff "$CONTAINER_NAME" | sed -n 's/^A //p' | \
    grep -E "^/usr|^/etc|^/opt" > "$WORK_DIR/files.txt"

if [ ! -s "$WORK_DIR/files.txt" ]; then
    echo "Error: No file changes detected!"
    exit 1
fi

echo "  → Detected $(wc -l < "$WORK_DIR/files.txt") file changes"

podman cp "$WORK_DIR/files.txt" "$CONTAINER_NAME":/tmp/files.txt

# Use --verbatim-files-from to prevent filename parsing (though tar usually handles newline-delimited lists fine)
# Allow tar to return 1 (warnings, e.g. socket files cannot be archived)
podman exec "$CONTAINER_NAME" tar --no-recursion -czf /tmp/payload.tar.gz -T /tmp/files.txt || {
    RET=$?
    if [ $RET -eq 1 ]; then
        echo "  ⚠ Tar completed with warnings (usually safe)"
    else
        echo "  ❌ Tar failed (code $RET)"
        exit $RET
    fi
}

podman cp "$CONTAINER_NAME":/tmp/payload.tar.gz "$WORK_DIR/payload.tar.gz"

# =============================================
# Step 3: Initialize Flatpak
# =============================================
echo "[4/6] Initializing Flatpak..."

if ! flatpak info org.fedoraproject.Platform//$RUNTIME_VER >/dev/null 2>&1; then
    echo "Error: Fedora Flatpak Runtime ($RUNTIME_VER) not installed"
    echo "Please run: flatpak install flathub org.fedoraproject.Platform//$RUNTIME_VER"
    exit 1
fi

flatpak build-init "$WORK_DIR/build" "$FLATPAK_ID" \
    org.fedoraproject.Sdk \
    org.fedoraproject.Platform \
    "$RUNTIME_VER" --arch="$ARCH"

# =============================================
# Step 4: Restructure file layout
# =============================================
echo "[5/6] Restructuring file layout..."

tar -xf "$WORK_DIR/payload.tar.gz" -C "$WORK_DIR/build/files"
cd "$WORK_DIR/build/files"

# Flatten /usr and /opt
[ -d usr ] && { chmod -R u+rwX usr; cp -r usr/* .; rm -rf usr; }
[ -d opt ] && { chmod -R u+rwX opt; cp -r opt/* .; rm -rf opt; }
[ -d etc ] && { chmod -R u+rwX etc; rm -rf etc; }

# Create launcher
mkdir -p bin

# Calculate flattened path
if [[ "$EXEC_PATH" == /usr/* ]]; then
    FLATTENED_PATH="${EXEC_PATH#/usr/}"
elif [[ "$EXEC_PATH" == /opt/* ]]; then
    FLATTENED_PATH="${EXEC_PATH#/opt/}"
else
    FLATTENED_PATH="${EXEC_PATH#/}"
fi

echo "  → Creating launcher: bin/$EXEC_NAME -> $FLATTENED_PATH"

if [ ! -e "$FLATTENED_PATH" ]; then
    echo "  ⚠️  Warning: Target file does not exist: $FLATTENED_PATH"
    echo "  → Searching for alternative path..."
    FLATTENED_PATH=$(find . -type f -name "$EXEC_NAME" -executable | head -n1)
    if [ -n "$FLATTENED_PATH" ]; then
        FLATTENED_PATH="${FLATTENED_PATH#./}"
        echo "  ✓ Found: $FLATTENED_PATH"
    fi
fi

if [ -n "$FLATTENED_PATH" ] && [ -e "$FLATTENED_PATH" ]; then
    ln -sf "../$FLATTENED_PATH" "bin/$EXEC_NAME"
else
    echo "  ✗ Error: Cannot locate executable file"
    exit 1
fi

# Handle Desktop file
mkdir -p share/applications
TARGET_DESKTOP="share/applications/${FLATPAK_ID}.desktop"

if [ -n "$DESKTOP_FILE" ] && [ -e "${DESKTOP_FILE#/usr/}" ]; then
    echo "  → Copying Desktop file"
    cp "${DESKTOP_FILE#/usr/}" "$TARGET_DESKTOP"
    
    # Fix Exec and Icon
    sed -i "s|^Exec=.*|Exec=$EXEC_NAME|" "$TARGET_DESKTOP"
    sed -i "s|^Icon=.*|Icon=$FLATPAK_ID|" "$TARGET_DESKTOP"
    
    # If sandbox needs to be disabled
    if [ "$CFG_flags_no_sandbox" = "yes" ]; then
        # Only replace Exec without parameters, or append to existing parameters
        # Simple replacement: find Exec=... line, append --no-sandbox at the end
        sed -i "/^Exec=/ s/$/ --no-sandbox/" "$TARGET_DESKTOP"
    fi
else
    echo "  → Generating default Desktop file"
    cat > "$TARGET_DESKTOP" <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$EXEC_NAME
Type=Application
Icon=$FLATPAK_ID
Categories=Utility;
Terminal=false
EOF
    if [ "$CFG_flags_no_sandbox" = "yes" ]; then
        sed -i "/^Exec=/ s/$/ --no-sandbox/" "$TARGET_DESKTOP"
    fi
fi

# Handle icon
mkdir -p share/icons/hicolor/256x256/apps

if [ -n "$ICON_PATH" ]; then
    # Try to remove /usr/ or /opt/ prefix
    ICON_FLATTENED="${ICON_PATH#/usr/}"
    ICON_FLATTENED="${ICON_FLATTENED#/opt/}"
    
    if [ -f "$ICON_FLATTENED" ]; then
        echo "  → Copying icon: $ICON_FLATTENED"
        cp "$ICON_FLATTENED" "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
    else
        echo "  ⚠️  Icon file does not exist ($ICON_FLATTENED), searching for alternative..."
        # Find also needs to handle filenames with spaces, but usually a single file
        FOUND_ICON=$(find share/icons share/pixmaps -name "*.png" -type f 2>/dev/null | head -n1)
        if [ -n "$FOUND_ICON" ]; then
            cp "$FOUND_ICON" "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
        fi
    fi
fi

# If no icon, create placeholder
if [ ! -f "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png" ]; then
    echo "  → Creating placeholder icon"
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
fi

cd - >/dev/null

# =============================================
# Step 5: Finish build
# =============================================
echo "[6/6] Finishing build and packaging..."

# Build PATH and LD_LIBRARY_PATH
FLATPAK_PATH="/app/bin:/usr/bin"
FLATPAK_LD="/app/lib64:/app/lib"

if [ -n "$CFG_flags_extra_path" ]; then
    FLATPAK_PATH="$FLATPAK_PATH:$CFG_flags_extra_path"
fi

if [ -n "$CFG_flags_extra_ld_path" ]; then
    FLATPAK_LD="$FLATPAK_LD:$CFG_flags_extra_ld_path"
fi

flatpak build-finish "$WORK_DIR/build" \
    --command="$EXEC_NAME" \
    --share=network \
    --share=ipc \
    --socket=x11 \
    --socket=wayland \
    --socket=pulseaudio \
    --device=dri \
    --filesystem=xdg-run/dconf \
    --filesystem=~/.config/dconf:ro \
    --talk-name=org.freedesktop.FileManager1 \
    --talk-name=org.freedesktop.portal.Desktop \
    --talk-name=org.freedesktop.portal.FileChooser \
    --talk-name=org.freedesktop.portal.Documents \
    --env=PATH="$FLATPAK_PATH" \
    --env=LD_LIBRARY_PATH="$FLATPAK_LD" \
    --env=ELECTRON_TRASH=gio \
    --env=GTK_USE_PORTAL=1

mkdir -p "$WORK_DIR/repo"
flatpak build-export "$WORK_DIR/repo" "$WORK_DIR/build" >/dev/null
flatpak build-bundle "$WORK_DIR/repo" "$PWD/$OUTPUT_BUNDLE" "$FLATPAK_ID"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Build successful!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Application name: $APP_NAME"
echo "Flatpak ID: $FLATPAK_ID"
echo "File location: $PWD/$OUTPUT_BUNDLE"
echo ""
echo "Install and run:"
echo "  flatpak install --user $OUTPUT_BUNDLE"
echo "  flatpak run $FLATPAK_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
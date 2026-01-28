#!/bin/bash
set -e

# =============================================
# RPM to Flatpak - Smart Detector (V2.3: Features Added)
# =============================================

FEDORA_VER=$(rpm -E %fedora)
BASE_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VER}"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$1" ]; then
    echo "Usage: $0 <rpm_file_path>"
    exit 1
fi

RPM_FILE=$(realpath "$1")
RPM_FILENAME=$(basename "$RPM_FILE")
if [ ! -f "$RPM_FILE" ]; then
    echo "Error: File not found: $RPM_FILE"
    exit 1
fi

APP_NAME=$(basename "$RPM_FILE" .rpm | sed 's/_x86_64//;s/_amd64//;s/-[0-9].*//' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="rpm_probe_$$"
CONF_FILE="${APP_NAME}.conf"

# Global variables
SELECTED_DESKTOP=""
SELECTED_EXEC=""
EXEC_NAME=""
SELECTED_ICON=""
NO_SANDBOX="no"
EXTRA_PATH=""
EXTRA_LD=""
EXTRA_REPOS=""
EXTRA_PERMS=""
FORCE_INSTALL="no"

cleanup() {
    trap - EXIT
    if [ -f "/tmp/rpm_probe_files_$$.txt" ]; then
        rm -f "/tmp/rpm_probe_files_$$.txt"
    fi
    echo ""
    echo -e "${BLUE}[*] Cleaning up probe container...${NC}"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

scan_files() {
    echo -e "${BLUE}  ↻ Scanning container filesystem...${NC}"
    podman diff "$CONTAINER_NAME" | awk '$1=="A" {print $2}' > /tmp/rpm_probe_files_$$.txt
    
    DESKTOP_LIST=$(grep '\.desktop$' /tmp/rpm_probe_files_$$.txt | grep '/applications/' | grep -v '/opt/' || echo "")
    DESKTOP_COUNT=$(echo "$DESKTOP_LIST" | grep -v '^$' | wc -l)
    
    EXEC_LIST=$(podman exec "$CONTAINER_NAME" bash -c "find /usr/bin /usr/sbin /opt -type f 2>/dev/null | head -n 100 | while read f; do if file \"\$f\" 2>/dev/null | grep -q ELF; then echo \"\$f\"; fi; done" | head -30)
    EXEC_COUNT=$(echo "$EXEC_LIST" | grep -v '^$' | wc -l)
    
    ICON_LIST=$(podman exec "$CONTAINER_NAME" bash -c "find /usr/share/icons /usr/share/pixmaps /opt -name '*.png' -o -name '*.svg' 2>/dev/null | head -n 50 | while read f; do size=\$(stat -c%s \"\$f\" 2>/dev/null || echo 0); echo \"\$size \$f\"; done | sort -rn | head -20 | awk '{print \$2}'")
    ICON_COUNT=$(echo "$ICON_LIST" | grep -v '^$' | wc -l)
}

enter_explorer() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔧 Enter Container Shell"
    echo "Tips: RPM file located at /root/$RPM_FILENAME"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    podman exec -it "$CONTAINER_NAME" bash || true
    echo ""
    echo "Interactive mode ended, continuing..."
    scan_files
}

init_container() {
    echo -e "${BLUE}[1/2] Starting environment and installing RPM...${NC}"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    podman run -d --name "$CONTAINER_NAME" \
        --tmpfs /tmp \
        --tmpfs /var/cache/dnf \
        "$BASE_IMAGE" sleep infinity >/dev/null

    echo "  → Uploading RPM to /root/$RPM_FILENAME"
    podman cp "$RPM_FILE" "$CONTAINER_NAME":/root/"$RPM_FILENAME"
    
    echo "  → Attempting automatic installation..."
    if ! podman exec "$CONTAINER_NAME" dnf install -y "/root/$RPM_FILENAME" >/dev/null 2>&1; then
        echo ""
        echo -e "${RED}❌ Automatic installation failed!${NC}"
        echo -e "Dependencies might be missing. You can configure Extra Repos later or solve manually."
        echo ""
        read -p "Enter container for manual handling? [Y/n] " fix_choice
        if [[ "$fix_choice" =~ ^[Nn]$ ]]; then
             exit 1
        else
             FORCE_INSTALL="yes"
             enter_explorer
        fi
    else
        echo -e "  ${GREEN}✓${NC} Installation complete"
    fi
}

step_desktop() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [1/4] Select Desktop File                                │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        if [ "$DESKTOP_COUNT" -eq 0 ]; then
            echo -e "  ${YELLOW}⚠ No standard .desktop file found${NC}"
        else
            echo "$DESKTOP_LIST" | nl -w4 -s'. ' | sed 's/^/  /'
        fi
        
        echo ""
        echo -e "  Actions: [number] select, [s] skip/none, ${CYAN}[e] manual explore${NC}, [m] manual input"
        read -p "  Your choice > " choice

        case "$choice" in
            e|E) enter_explorer ;;
            s|S) SELECTED_DESKTOP=""; return ;;
            m|M) 
                read -p "  Enter full path: " manual_path
                SELECTED_DESKTOP="$manual_path"
                return
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    SELECTED_DESKTOP=$(echo "$DESKTOP_LIST" | sed -n "${choice}p")
                    if [ -n "$SELECTED_DESKTOP" ]; then
                        echo -e "  ${GREEN}✓ Selected: $SELECTED_DESKTOP${NC}"
                        return
                    fi
                fi
                echo "  Invalid choice."
                ;;
        esac
    done
}

step_exec() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [2/4] Select Main Program (Executable)                   │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        SUGGESTED=""
        if [ -n "$SELECTED_DESKTOP" ]; then
            CMD_IN_DESKTOP=$(podman exec "$CONTAINER_NAME" grep '^Exec=' "$SELECTED_DESKTOP" | head -n1 | sed 's/^Exec=//' | awk '{print $1}' | tr -d '"' | tr -d "'")
            # WPS special handling: Exec is often /usr/bin/wps %f, we only need the path part
            CMD_IN_DESKTOP=$(echo "$CMD_IN_DESKTOP" | awk '{print $1}')
            
            if [[ "$CMD_IN_DESKTOP" == /* ]]; then
                SUGGESTED="$CMD_IN_DESKTOP"
            else
                # Try to find in /usr/bin or /usr/sbin
                SUGGESTED=$(podman exec "$CONTAINER_NAME" which "$CMD_IN_DESKTOP" 2>/dev/null || echo "")
                
                # If found, check if it's a wrapper script and extract real path
                if [ -n "$SUGGESTED" ]; then
                    # Check if it's a script (not ELF binary)
                    if ! podman exec "$CONTAINER_NAME" file "$SUGGESTED" 2>/dev/null | grep -q ELF; then
                        # Try to extract path from script (common patterns: /opt/..., /usr/lib/...)
                        REAL_PATH=$(podman exec "$CONTAINER_NAME" bash -c "grep -oE '(/opt/[^[:space:]\"'\'']+|/usr/lib[^[:space:]\"'\'']+)' '$SUGGESTED' 2>/dev/null | grep -E '(^/opt/|^/usr/lib/)' | head -n1")
                        if [ -n "$REAL_PATH" ] && podman exec "$CONTAINER_NAME" test -f "$REAL_PATH"; then
                            echo "  → Detected wrapper script, real binary: $REAL_PATH"
                            SUGGESTED="$REAL_PATH"
                        fi
                    fi
                fi
                
                # If still not found, try to find symlink in bin directories
                if [ -z "$SUGGESTED" ]; then
                    SUGGESTED=$(podman exec "$CONTAINER_NAME" bash -c "find /usr/bin /usr/sbin -type l -name '$CMD_IN_DESKTOP' 2>/dev/null | head -n1")
                    if [ -n "$SUGGESTED" ]; then
                        # Get the target of the symlink
                        LINK_TARGET=$(podman exec "$CONTAINER_NAME" readlink -f "$SUGGESTED" 2>/dev/null || echo "")
                        if [ -n "$LINK_TARGET" ] && podman exec "$CONTAINER_NAME" test -f "$LINK_TARGET"; then
                            SUGGESTED="$LINK_TARGET"
                        fi
                    fi
                fi
            fi
        fi

        if [ -n "$SUGGESTED" ]; then
            echo -e "  ${BLUE}★ Recommended: $SUGGESTED${NC}"
        fi

        echo "  Detected binary files:"
        echo "$EXEC_LIST" | nl -w4 -s'. ' | sed 's/^/  /'
        
        echo ""
        echo -e "  Actions: [number] select, [a] use recommended, ${CYAN}[e] manual explore${NC}, [m] manual input"
        read -p "  Your choice > " choice

        case "$choice" in
            e|E) enter_explorer ;;
            a|A)
                if [ -n "$SUGGESTED" ]; then SELECTED_EXEC="$SUGGESTED"; break; fi
                ;;
            m|M)
                read -p "  Enter executable full path: " manual_exec
                SELECTED_EXEC="$manual_exec"
                break
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    SELECTED_EXEC=$(echo "$EXEC_LIST" | sed -n "${choice}p")
                    if [ -n "$SELECTED_EXEC" ]; then break; fi
                fi
                ;;
        esac
    done
    EXEC_NAME=$(basename "$SELECTED_EXEC")
    echo -e "  ${GREEN}✓ Selected: $SELECTED_EXEC${NC}"
}

step_icon() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [3/4] Select Icon                                        │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        SUGGESTED_ICON=""
        if [ -n "$SELECTED_DESKTOP" ]; then
             ICON_NAME=$(podman exec "$CONTAINER_NAME" grep '^Icon=' "$SELECTED_DESKTOP" | head -n1 | cut -d= -f2)
             if [ -n "$ICON_NAME" ]; then
                 SUGGESTED_ICON=$(echo "$ICON_LIST" | grep "$ICON_NAME" | head -n1)
             fi
        fi

        if [ -n "$SUGGESTED_ICON" ]; then
             echo -e "  ${BLUE}★ Recommended: $SUGGESTED_ICON${NC}"
        fi

        echo "  Detected icons (Top 10):"
        echo "$ICON_LIST" | head -10 | nl -w4 -s'. ' | sed 's/^/  /'

        echo ""
        # [FEATURE] Added [n] none option
        echo -e "  Actions: [number] select, [a] use recommended, [n] none (no icon), ${CYAN}[e] explore${NC}, [m] manual"
        read -p "  Your choice > " choice

        case "$choice" in
            n|N) SELECTED_ICON="none"; return ;;
            e|E) enter_explorer ;;
            a|A) 
                if [ -n "$SUGGESTED_ICON" ]; then SELECTED_ICON="$SUGGESTED_ICON"; return; fi
                ;;
            m|M)
                read -p "  Enter icon path: " manual_icon
                SELECTED_ICON="$manual_icon"
                return
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    SELECTED_ICON=$(echo "$ICON_LIST" | sed -n "${choice}p")
                    if [ -n "$SELECTED_ICON" ]; then
                        echo -e "  ${GREEN}✓ Selected: $SELECTED_ICON${NC}"
                        return
                    fi
                fi
                ;;
        esac
    done
}

step_flags() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [4/4] Runtime Parameters                                 │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        read -p "  Disable internal sandbox (--no-sandbox)? [y/N]: " sb_input
        if [ "$sb_input" = "y" ] || [ "$sb_input" = "Y" ]; then NO_SANDBOX="yes"; else NO_SANDBOX="no"; fi

        read -p "  Extra PATH directories (optional): " EXTRA_PATH
        read -p "  Extra LD_LIBRARY_PATH (optional): " EXTRA_LD

        # [FEATURE] Extra Repos
        echo -e "  Extra Repos URL (e.g. https://.../foo.repo) - used during build:"
        read -p "  > " EXTRA_REPOS
        
        # [FEATURE] Extra Permissions
        echo -e "  Extra Flatpak Permissions (e.g. --device=all --filesystem=/tmp):"
        read -p "  > " EXTRA_PERMS
        
        break
    done
}

# =============================================
# Main Logic
# =============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RPM Detector - Interactive Mode (V2.3)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

init_container
scan_files
step_desktop
step_exec
step_icon
step_flags

# =============================================
# Generate Configuration
# =============================================

cat > "$CONF_FILE" <<EOF
# RPM to Flatpak Configuration File
# Generated: $(date)

[meta]
app_name=$APP_NAME
rpm_file=$(basename "$RPM_FILE")
force_install=$FORCE_INSTALL
extra_repos=$EXTRA_REPOS

[desktop]
desktop_file=$SELECTED_DESKTOP

[exec]
exec_path=$SELECTED_EXEC
exec_name=$EXEC_NAME

[icon]
icon_path=$SELECTED_ICON

[flags]
no_sandbox=$NO_SANDBOX
extra_path=$EXTRA_PATH
extra_ld_path=$EXTRA_LD
extra_permissions=$EXTRA_PERMS
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Configuration generated successfully${NC}"
echo "File: $CONF_FILE"
echo -e "${YELLOW}Next step: ./rpm2flatpak-build.sh $CONF_FILE${NC}"
#!/bin/bash
set -e

# ================= 配置 =================
FEDORA_VER="43"
RUNTIME_VER="f43"
BASE_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VER}"
ARCH=$(uname -m)
# =======================================

if [ -z "$1" ]; then
    echo "用法: $0 <包名 或 本地rpm路径>"
    exit 1
fi

INPUT_ARG="$1"
RPM_FILE=""
APP_NAME=""

if [ -f "$INPUT_ARG" ]; then
    RPM_FILE=$(realpath "$INPUT_ARG")
    APP_NAME=$(basename "$INPUT_ARG" .rpm | cut -d- -f1)
else
    APP_NAME="$INPUT_ARG"
fi

SAFE_NAME=$(echo "$APP_NAME" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
FLATPAK_ID="org.rpm.${SAFE_NAME}"
OUTPUT_BUNDLE="${APP_NAME}.flatpak"

WORK_DIR=$(mktemp -d -t rpm2flatpak.XXXXXX)
CONTAINER_NAME="builder_$(basename $WORK_DIR)"

echo "[*] 工作目录: $WORK_DIR"
echo "[*] 应用 ID: $FLATPAK_ID"

cleanup() {
    echo ""
    echo "[*] 正在清理环境..."
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    echo "[*] 清理完成。"
}
trap cleanup EXIT INT TERM

# 1. 启动容器
echo "[1/8] 启动构建容器..."
podman run -d --rm \
    --name "$CONTAINER_NAME" \
    --tmpfs /tmp \
    --tmpfs /var/cache/dnf \
    --tmpfs /var/log \
    --tmpfs /var/tmp \
    "$BASE_IMAGE" sleep infinity >/dev/null

# 2. 安装 RPM
echo "[2/8] 安装软件..."
if [ -n "$RPM_FILE" ]; then
    podman cp "$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
    podman exec "$CONTAINER_NAME" dnf install -y /tmp/target.rpm || echo "警告: 安装脚本报错 (忽略)"
else
    podman exec "$CONTAINER_NAME" dnf install -y "$INPUT_ARG" || echo "警告: 安装脚本报错 (忽略)"
fi

# 3. 提取文件
echo "[3/8] 提取文件层..."
podman diff "$CONTAINER_NAME" | awk '$1=="A" {print $2}' | grep -E "^/usr|^/etc|^/opt" > "$WORK_DIR/files.txt"
[ ! -s "$WORK_DIR/files.txt" ] && { echo "错误：未检测到文件变更！"; exit 1; }

podman cp "$WORK_DIR/files.txt" "$CONTAINER_NAME":/tmp/files.txt
podman exec "$CONTAINER_NAME" tar --no-recursion -czf /tmp/payload.tar.gz -T /tmp/files.txt
podman cp "$CONTAINER_NAME":/tmp/payload.tar.gz "$WORK_DIR/payload.tar.gz"

# 4. 初始化
echo "[4/8] 初始化 Flatpak..."
flatpak build-init "$WORK_DIR/build" "$FLATPAK_ID" org.fedoraproject.Sdk org.fedoraproject.Platform "$RUNTIME_VER" --arch="$ARCH"

# 5. 重构布局
echo "[5/8] 重构文件布局..."
tar -xf "$WORK_DIR/payload.tar.gz" -C "$WORK_DIR/build/files"
cd "$WORK_DIR/build/files"

[ -d "usr" ] && { cp -r usr/* .; rm -rf usr; }
[ -d "opt" ] && { cp -r opt/* .; rm -rf opt; }
[ -d "etc" ] && { mkdir -p etc-backup; cp -r etc/* etc-backup/; rm -rf etc; mv etc-backup etc; }

# 6. 处理桌面整合 (修复图标逻辑)
echo "[6/8] 处理桌面整合..."

# === Try Block Start ===
set +e 
(
    mkdir -p share/applications
    mkdir -p share/icons/hicolor/256x256/apps

    # --- Desktop 处理 ---
    # 智能查找：先找包含名字的，找不到再找任意的
    FOUND_DESKTOP=$(find . -name "*${APP_NAME}*.desktop" 2>/dev/null | head -n 1)
    [ -z "$FOUND_DESKTOP" ] && FOUND_DESKTOP=$(find . -name "*${SAFE_NAME}*.desktop" 2>/dev/null | head -n 1)
    [ -z "$FOUND_DESKTOP" ] && FOUND_DESKTOP=$(find . -name "*.desktop" 2>/dev/null | head -n 1)

    TARGET_DESKTOP="share/applications/${FLATPAK_ID}.desktop"

    if [ -n "$FOUND_DESKTOP" ]; then
        echo "    -> 锁定 Desktop 文件: $FOUND_DESKTOP"
        cp "$FOUND_DESKTOP" "$TARGET_DESKTOP" || exit 1 
        
        # 修正 Exec 和 Icon
        sed -i -E 's|^Exec=(/.*/)(.*)|Exec=\2|' "$TARGET_DESKTOP"
        sed -i "s|^Icon=.*|Icon=${FLATPAK_ID}|" "$TARGET_DESKTOP"
    else
        echo "    -> 未找到 .desktop，生成默认..."
        cat > "$TARGET_DESKTOP" <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$APP_NAME
Type=Application
Icon=$FLATPAK_ID
Categories=Utility;
EOF
    fi

    # --- Icon 处理 (核心修复) ---
    echo "    -> 正在搜索最佳图标..."
    
    # 策略：查找所有 png 文件 -> 获取"大小 路径" -> 按大小倒序 -> 取第一个 -> 提取路径
    # -type f : 排除目录 (解决了 'omitting directory wechat' 错误)
    
    # 1. 优先找名字匹配的 PNG (忽略大小写)
    find . -type f -iname "*${APP_NAME}*.png" -printf "%s %p\n" > icons_list.txt
    
    # 2. 如果没找到，找包含 'logo' 的 PNG
    if [ ! -s icons_list.txt ]; then
        find . -type f -iname "*logo*.png" -printf "%s %p\n" > icons_list.txt
    fi
    
    # 3. 实在不行，找任意 PNG
    if [ ! -s icons_list.txt ]; then
        find . -type f -iname "*.png" -printf "%s %p\n" > icons_list.txt
    fi

    FOUND_ICON=""
    if [ -s icons_list.txt ]; then
        # sort -rn: 按数字逆序 (最大的文件在最前)
        FOUND_ICON=$(sort -rn icons_list.txt | head -n 1 | awk '{print $2}')
    fi
    rm -f icons_list.txt

    if [ -n "$FOUND_ICON" ]; then
        echo "    -> 锁定图标文件 (Size: $(du -h "$FOUND_ICON" | cut -f1)): $FOUND_ICON"
        cp "$FOUND_ICON" "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
    else
        echo "    [!] 警告: 未找到任何 PNG 图标文件！应用将显示默认图标。"
    fi
)
set -e 
# === Try Block End ===

# 7. 二进制修补与链接
echo "[7/8] 修补路径与创建启动入口..."

# A. 修复软链接 (/opt -> /app/opt)
find . -type l | while read l; do
    target=$(readlink "$l")
    if [[ "$target" == /opt/* ]]; then
        new_target="/app${target#/opt}"
        ln -sf "$new_target" "$l"
    fi
done

# B. 修复 Shebang
grep -rIl "#!/usr/bin/" . | xargs sed -i 's|#!/usr/bin/|#!/app/bin/|g' 2>/dev/null || true

# C. 注入伪造包管理器 (解决 rpm lock 报错)
mkdir -p bin
echo -e '#!/bin/sh\nexit 0' > bin/rpm
echo -e '#!/bin/sh\nexit 0' > bin/dnf
echo -e '#!/bin/sh\nexit 0' > bin/yum
chmod +x bin/rpm bin/dnf bin/yum
echo "    -> 已注入伪造的包管理器 (rpm/dnf/yum) 以规避启动报错"

# D. 确定启动命令并链接
DESKTOP_EXEC=$(grep '^Exec=' "share/applications/${FLATPAK_ID}.desktop" | cut -d= -f2 | awk '{print $1}')
[ -z "$DESKTOP_EXEC" ] && DESKTOP_EXEC="$APP_NAME"
echo "    -> 目标启动命令名: $DESKTOP_EXEC"

if [ -x "bin/$DESKTOP_EXEC" ] || [ -L "bin/$DESKTOP_EXEC" ]; then
    echo "    -> 在 /app/bin 中找到 '$DESKTOP_EXEC'，无需修补。"
else
    # 搜索文件或软链接
    FOUND_BIN=$(find . -name "$DESKTOP_EXEC" \( -type f -o -type l \) -not -path "./share/*" | head -n 1)
    if [ -n "$FOUND_BIN" ]; then
        echo "    -> 找到真实入口: $FOUND_BIN"
        ln -sf "../$FOUND_BIN" "bin/$DESKTOP_EXEC"
    else
        echo "    [!] 警告: 未找到名为 $DESKTOP_EXEC 的入口，尝试模糊搜索..."
        FOUND_BIN_ALT=$(find . -name "*${APP_NAME}*" \( -type f -o -type l \) -executable -not -path "./share/*" | head -n 1)
        if [ -n "$FOUND_BIN_ALT" ]; then
             echo "    -> 找到替代: $FOUND_BIN_ALT"
             ln -sf "../$FOUND_BIN_ALT" "bin/$DESKTOP_EXEC"
        fi
    fi
fi

cd - >/dev/null

# 8. 完成构建
echo "[8/8] 完成构建并打包..."

CMD_FINAL=$(basename "$DESKTOP_EXEC")
echo "    -> 最终启动参数: $CMD_FINAL"

flatpak build-finish "$WORK_DIR/build" \
    --command="$CMD_FINAL" \
    --share=network \
    --share=ipc \
    --socket=x11 \
    --socket=wayland \
    --socket=pulseaudio \
    --device=dri \
    --filesystem=xdg-download \
    --env=PATH=/app/bin:/usr/bin:/app/${APP_NAME}:/app/wechat \
    --env=LD_LIBRARY_PATH=/app/lib64:/app/lib \
    --allow=devel

mkdir -p "$WORK_DIR/repo"
flatpak build-export "$WORK_DIR/repo" "$WORK_DIR/build"
flatpak build-bundle "$WORK_DIR/repo" "$PWD/$OUTPUT_BUNDLE" "$FLATPAK_ID"

echo "========================================"
echo "SUCCESS! 转换完成。"
echo "文件位置: $PWD/$OUTPUT_BUNDLE"
echo "安装: flatpak install --user $OUTPUT_BUNDLE"
echo "运行: flatpak run $FLATPAK_ID"
echo "========================================"
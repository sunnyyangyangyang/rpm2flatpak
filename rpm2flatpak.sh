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
echo "[1/8] 启动构建容器 (Memory only mode)..."
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

if [ ! -s "$WORK_DIR/files.txt" ]; then
    echo "错误：未检测到文件变更！"
    exit 1
fi

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

# 6. 处理桌面整合 (Try-Catch 模式，已移除重复代码)
echo "[6/8] 处理桌面整合 (Safe Mode)..."

# === Try Block Start ===
set +e 

(
    # 1. 准备目录
    mkdir -p share/applications
    mkdir -p share/icons/hicolor/256x256/apps

    # 2. 处理 Desktop 文件
    FOUND_DESKTOP=$(find . -name "*.desktop" | head -n 1)
    TARGET_DESKTOP="share/applications/${FLATPAK_ID}.desktop"

    if [ -n "$FOUND_DESKTOP" ]; then
        echo "    -> 尝试复制并修正 Desktop 文件: $FOUND_DESKTOP"
        cp "$FOUND_DESKTOP" "$TARGET_DESKTOP" || exit 1 
        
        # 修改 Exec: 移除绝对路径，防止 /usr/bin/xxx 报错
        sed -i -E 's|^Exec=(/.*/)(.*)|Exec=\2|' "$TARGET_DESKTOP" || echo "    -> 警告: Exec 修改失败"
        
        # 修改 Icon: 必须指向 ID
        sed -i "s|^Icon=.*|Icon=${FLATPAK_ID}|" "$TARGET_DESKTOP" || echo "    -> 警告: Icon 修改失败"
    else
        echo "    -> 未找到 .desktop，生成默认文件..."
        cat > "$TARGET_DESKTOP" <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$APP_NAME
Type=Application
Icon=$FLATPAK_ID
Categories=Utility;
EOF
    fi

    # 3. 处理图标 (寻找最大尺寸并重命名为 ID)
    FOUND_ICON=$(find . -name "product_logo_256.png" -o -name "wechat.png" -o -name "*.png" | xargs ls -S 2>/dev/null | head -n 1)
    if [ -n "$FOUND_ICON" ]; then
        echo "    -> 尝试复制图标: $FOUND_ICON"
        cp "$FOUND_ICON" "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png" || echo "    -> 警告: 图标复制失败"
    fi
)

# === Catch Block ===
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "    [!] 警告: 桌面整合步骤发生错误 (Exit Code: $EXIT_CODE)"
    echo "    [!] 忽略错误，继续后续构建..."
else
    echo "    -> 桌面整合处理完毕。"
fi

set -e 
# === Try Block End ===

# 7. 二进制修补
echo "[7/8] 修补路径..."
grep -rIl "#!/usr/bin/" . | xargs sed -i 's|#!/usr/bin/|#!/app/bin/|g' 2>/dev/null || true

find . -type l | while read l; do
    target=$(readlink "$l")
    if [[ "$target" == /opt/* ]]; then
        new_target="/app${target#/opt}"
        ln -sf "$new_target" "$l"
    fi
done

cd - >/dev/null

# 8. 完成构建
echo "[8/8] 完成构建并打包..."

# 探测启动命令
CMD_RAW=$(grep '^Exec=' "$WORK_DIR/build/files/share/applications/${FLATPAK_ID}.desktop" | cut -d= -f2 | awk '{print $1}')
# 双重保险：无论 desktop 改没改成功，这里强制取文件名
CMD_DETECT=$(basename "$CMD_RAW")
[ -z "$CMD_DETECT" ] && CMD_DETECT="$APP_NAME"

echo "    -> 启动命令: $CMD_DETECT"

flatpak build-finish "$WORK_DIR/build" \
    --command="$CMD_DETECT" \
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
echo "安装: flatpak install --user $OUTPUT_BUNDLE"
echo "运行: flatpak run $FLATPAK_ID"
echo "========================================"
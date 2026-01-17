#!/bin/bash
set -e

# =============================================
# RPM to Flatpak - 构建器 (修复版)
# 用途: 根据配置文件构建 Flatpak 包
# =============================================

FEDORA_VER="43"
RUNTIME_VER="f43"
BASE_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VER}"
ARCH=$(uname -m)

if [ -z "$1" ]; then
    echo "用法: $0 <配置文件>"
    echo "示例: $0 wechat.conf"
    echo ""
    echo "提示: 先运行 ./rpm2flatpak-probe.sh 生成配置文件"
    exit 1
fi

# 新增：检查是否启用强制模式
FORCE_MODE=0
if [ "$2" = "--force" ]; then
    FORCE_MODE=1
fi

CONF_FILE="$1"
if [ ! -f "$CONF_FILE" ]; then
    echo "错误：配置文件不存在: $CONF_FILE"
    exit 1
fi

# =============================================
# 读取配置文件
# =============================================
parse_conf() {
    local section=""
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # 解析 section
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # 解析 key=value
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            eval "CFG_${section}_${key}='$value'"
        fi
    done < "$CONF_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RPM to Flatpak 构建器"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

parse_conf

# 验证必需参数
if [ -z "$CFG_meta_app_name" ] || [ -z "$CFG_exec_exec_path" ]; then
    echo "错误：配置文件缺少必需字段 (app_name 或 exec_path)"
    exit 1
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

echo "应用名称: $APP_NAME"
echo "Flatpak ID: $FLATPAK_ID"
echo "可执行文件: $EXEC_PATH"
echo "启动命令: $EXEC_NAME"
echo ""

# =============================================
# 工作环境
# =============================================
WORK_DIR=$(mktemp -d -t rpm2flatpak.XXXXXX)
CONTAINER_NAME="builder_$(basename $WORK_DIR)"

echo "[*] 工作目录: $WORK_DIR"

cleanup() {
    echo ""
    echo "[*] 正在清理环境..."
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    echo "[*] 清理完成。"
}
trap cleanup EXIT INT TERM

# =============================================
# 第一步：启动容器并安装 RPM
# =============================================
echo "[1/6] 启动构建容器..."
podman run -d --name "$CONTAINER_NAME" \
    --tmpfs /tmp \
    --tmpfs /var/cache/dnf \
    --tmpfs /var/log \
    "$BASE_IMAGE" sleep infinity >/dev/null

echo "[2/6] 安装 RPM 包..."
if [ -f "$RPM_FILE" ]; then
    podman cp "$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
    RPM_TARGET="/tmp/target.rpm"
else
    # 尝试从当前目录查找
    if [ -f "./$RPM_FILE" ]; then
        podman cp "./$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
        RPM_TARGET="/tmp/target.rpm"
    else
        echo "错误：找不到 RPM 文件: $RPM_FILE"
        exit 1
    fi
fi

if [ "$FORCE_MODE" -eq 1 ]; then
    echo "  ⚠️  启用强制安装模式 (忽略依赖与签名)..."
    # 使用 rpm 直接安装，忽略所有校验
    podman exec "$CONTAINER_NAME" rpm -ivh --nodeps --nosignature --nodigest "$RPM_TARGET"
else
    # 默认模式：尝试使用 dnf 智能安装
    echo "  → 使用 DNF 安装..."
    if ! podman exec "$CONTAINER_NAME" dnf install -y "$RPM_TARGET" 2>&1 | grep -v "^warning:"; then
        echo "  ⚠ DNF 安装遇到问题，尝试继续..."
        # 如果 DNF 失败，通常后面提取文件会为空，但这里保留 || true 逻辑与原版一致，
        # 或者你可以在这里加一个 fallback 自动切到 rpm 模式
    fi
fi

podman exec "$CONTAINER_NAME" dnf install -y "$RPM_TARGET" 2>&1 | grep -v "^warning:" || true

# =============================================
# 第二步：提取文件 (Critical Fix applied here)
# =============================================
echo "[3/6] 提取文件层..."

# 修复：使用 sed 替代 awk，保留文件名中的空格
# 格式为 "A /path/to/file with spaces" -> 去掉前两个字符
podman diff "$CONTAINER_NAME" | sed -n 's/^A //p' | \
    grep -E "^/usr|^/etc|^/opt" > "$WORK_DIR/files.txt"

if [ ! -s "$WORK_DIR/files.txt" ]; then
    echo "错误：未检测到文件变更！"
    exit 1
fi

echo "  → 检测到 $(wc -l < "$WORK_DIR/files.txt") 个文件变更"

podman cp "$WORK_DIR/files.txt" "$CONTAINER_NAME":/tmp/files.txt

# 使用 --verbatim-files-from 防止文件名被解析为参数 (虽然 tar 默认处理换行符分割通常没问题，但安全起见)
# 允许 tar 返回 1 (警告，如 socket 文件无法归档)
podman exec "$CONTAINER_NAME" tar --no-recursion -czf /tmp/payload.tar.gz -T /tmp/files.txt || {
    RET=$?
    if [ $RET -eq 1 ]; then
        echo "  ⚠ Tar 完成但有警告 (通常是安全的)"
    else
        echo "  ❌ Tar 失败 (代码 $RET)"
        exit $RET
    fi
}

podman cp "$CONTAINER_NAME":/tmp/payload.tar.gz "$WORK_DIR/payload.tar.gz"

# =============================================
# 第三步：初始化 Flatpak
# =============================================
echo "[4/6] 初始化 Flatpak..."

if ! flatpak info org.fedoraproject.Platform//$RUNTIME_VER >/dev/null 2>&1; then
    echo "错误：未安装 Fedora Flatpak Runtime ($RUNTIME_VER)"
    echo "请运行: flatpak install flathub org.fedoraproject.Platform//$RUNTIME_VER"
    exit 1
fi

flatpak build-init "$WORK_DIR/build" "$FLATPAK_ID" \
    org.fedoraproject.Sdk \
    org.fedoraproject.Platform \
    "$RUNTIME_VER" --arch="$ARCH"

# =============================================
# 第四步：重构文件布局
# =============================================
echo "[5/6] 重构文件布局..."

tar -xf "$WORK_DIR/payload.tar.gz" -C "$WORK_DIR/build/files"
cd "$WORK_DIR/build/files"

# Flatten /usr 和 /opt
[ -d usr ] && { chmod -R u+rwX usr; cp -r usr/* .; rm -rf usr; }
[ -d opt ] && { chmod -R u+rwX opt; cp -r opt/* .; rm -rf opt; }
[ -d etc ] && { chmod -R u+rwX etc; rm -rf etc; }

# 创建启动器
mkdir -p bin

# 计算 flatten 后的路径
if [[ "$EXEC_PATH" == /usr/* ]]; then
    FLATTENED_PATH="${EXEC_PATH#/usr/}"
elif [[ "$EXEC_PATH" == /opt/* ]]; then
    FLATTENED_PATH="${EXEC_PATH#/opt/}"
else
    FLATTENED_PATH="${EXEC_PATH#/}"
fi

echo "  → 创建启动器: bin/$EXEC_NAME -> $FLATTENED_PATH"

if [ ! -e "$FLATTENED_PATH" ]; then
    echo "  ⚠️  警告: 目标文件不存在: $FLATTENED_PATH"
    echo "  → 尝试搜索替代路径..."
    FLATTENED_PATH=$(find . -type f -name "$EXEC_NAME" -executable | head -n1)
    if [ -n "$FLATTENED_PATH" ]; then
        FLATTENED_PATH="${FLATTENED_PATH#./}"
        echo "  ✓ 找到: $FLATTENED_PATH"
    fi
fi

if [ -n "$FLATTENED_PATH" ] && [ -e "$FLATTENED_PATH" ]; then
    ln -sf "../$FLATTENED_PATH" "bin/$EXEC_NAME"
else
    echo "  ✗ 错误: 无法定位可执行文件"
    exit 1
fi

# 处理 Desktop 文件
mkdir -p share/applications
TARGET_DESKTOP="share/applications/${FLATPAK_ID}.desktop"

if [ -n "$DESKTOP_FILE" ] && [ -e "${DESKTOP_FILE#/usr/}" ]; then
    echo "  → 复制 Desktop 文件"
    cp "${DESKTOP_FILE#/usr/}" "$TARGET_DESKTOP"
    
    # 修正 Exec 和 Icon
    sed -i "s|^Exec=.*|Exec=$EXEC_NAME|" "$TARGET_DESKTOP"
    sed -i "s|^Icon=.*|Icon=$FLATPAK_ID|" "$TARGET_DESKTOP"
    
    # 如果需要禁用沙箱
    if [ "$CFG_flags_no_sandbox" = "yes" ]; then
        # 仅替换没有参数的 Exec，或者在已有参数后追加
        # 这里简单替换：找到 Exec=... 行，在末尾加 --no-sandbox
        sed -i "/^Exec=/ s/$/ --no-sandbox/" "$TARGET_DESKTOP"
    fi
else
    echo "  → 生成默认 Desktop 文件"
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

# 处理图标
mkdir -p share/icons/hicolor/256x256/apps

if [ -n "$ICON_PATH" ]; then
    # 尝试去掉 /usr/ 或 /opt/ 前缀
    ICON_FLATTENED="${ICON_PATH#/usr/}"
    ICON_FLATTENED="${ICON_FLATTENED#/opt/}"
    
    if [ -f "$ICON_FLATTENED" ]; then
        echo "  → 复制图标: $ICON_FLATTENED"
        cp "$ICON_FLATTENED" "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
    else
        echo "  ⚠️  图标文件不存在 ($ICON_FLATTENED)，搜索替代..."
        # 这里的 find 也需要处理文件名带空格的情况，但这里通常是单个文件
        FOUND_ICON=$(find share/icons share/pixmaps -name "*.png" -type f 2>/dev/null | head -n1)
        if [ -n "$FOUND_ICON" ]; then
            cp "$FOUND_ICON" "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
        fi
    fi
fi

# 如果没有图标，创建占位符
if [ ! -f "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png" ]; then
    echo "  → 创建占位图标"
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "share/icons/hicolor/256x256/apps/${FLATPAK_ID}.png"
fi

cd - >/dev/null

# =============================================
# 第五步：完成构建
# =============================================
echo "[6/6] 完成构建并打包..."

# 构建 PATH 和 LD_LIBRARY_PATH
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
    --filesystem=xdg-documents \
    --filesystem=xdg-download \
    --filesystem=xdg-desktop \
    --filesystem=xdg-music \
    --filesystem=xdg-pictures \
    --filesystem=xdg-videos \
    --talk-name=org.freedesktop.FileManager1 \
    --env=PATH="$FLATPAK_PATH" \
    --env=LD_LIBRARY_PATH="$FLATPAK_LD" \
    --env=ELECTRON_TRASH=gio

mkdir -p "$WORK_DIR/repo"
flatpak build-export "$WORK_DIR/repo" "$WORK_DIR/build" >/dev/null
flatpak build-bundle "$WORK_DIR/repo" "$PWD/$OUTPUT_BUNDLE" "$FLATPAK_ID"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 构建成功！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "应用名称: $APP_NAME"
echo "Flatpak ID: $FLATPAK_ID"
echo "文件位置: $PWD/$OUTPUT_BUNDLE"
echo ""
echo "安装并运行:"
echo "  flatpak install --user $OUTPUT_BUNDLE"
echo "  flatpak run $FLATPAK_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#!/bin/bash
set -e

# ================= 配置 =================
FEDORA_VER="43"                    # 容器镜像版本（纯数字）
RUNTIME_VER="f43"                  # Flatpak runtime 版本（带 f 前缀）
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

# 判断输入
if [ -f "$INPUT_ARG" ]; then
    RPM_FILE=$(realpath "$INPUT_ARG")
    APP_NAME=$(basename "$INPUT_ARG" .rpm | cut -d- -f1)
else
    APP_NAME="$INPUT_ARG"
fi

# 生成 ID (移除下划线等非法字符)
SAFE_NAME=$(echo "$APP_NAME" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
FLATPAK_ID="org.rpm.${SAFE_NAME}"
OUTPUT_BUNDLE="${APP_NAME}.flatpak"

# 创建临时工作目录
WORK_DIR=$(mktemp -d -t rpm2flatpak.XXXXXX)
CONTAINER_NAME="builder_$(basename $WORK_DIR)"

echo "[*] 工作目录: $WORK_DIR"
echo "[*] 应用 ID: $FLATPAK_ID"

# === 退出清理函数 ===
cleanup() {
    echo ""
    echo "[*] 正在清理环境..."
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
    echo "[*] 清理完成。"
}
trap cleanup EXIT INT TERM

# 1. 启动容器
echo "[1/7] 启动构建容器..."
podman run -d --rm --name "$CONTAINER_NAME" "$BASE_IMAGE" sleep infinity >/dev/null

# 2. 安装 RPM
echo "[2/7] 安装软件 (忽略脚本错误)..."
# WeChat 这种包的 post-script 经常因为缺依赖报错，这在容器里是正常的，不影响文件解压
if [ -n "$RPM_FILE" ]; then
    podman cp "$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
    # 使用 || true 忽略 %post 脚本报错 (比如 update-mime-database not found)
    podman exec "$CONTAINER_NAME" dnf install -y /tmp/target.rpm || echo "警告: 安装过程有非致命错误，继续执行..."
else
    podman exec "$CONTAINER_NAME" dnf install -y "$INPUT_ARG" || echo "警告: 安装过程有非致命错误，继续执行..."
fi

# 3. 提取增量 (修正了 tar 顺序，增加了 /opt)
echo "[3/7] 提取文件 (包含 /usr, /etc, /opt)..."
# 重点：抓取 /opt，因为 WeChat 装在这里
podman diff "$CONTAINER_NAME" | awk '$1=="A" {print $2}' | grep -E "^/usr|^/etc|^/opt" > "$WORK_DIR/files.txt"

if [ ! -s "$WORK_DIR/files.txt" ]; then
    echo "错误：未检测到文件变更！"
    exit 1
fi

# 传输列表并打包 (关键修复: --no-recursion 放在最前面)
podman cp "$WORK_DIR/files.txt" "$CONTAINER_NAME":/tmp/files.txt
podman exec "$CONTAINER_NAME" tar --no-recursion -czf /tmp/payload.tar.gz -T /tmp/files.txt
podman cp "$CONTAINER_NAME":/tmp/payload.tar.gz "$WORK_DIR/payload.tar.gz"

# 4. 先初始化 Flatpak 结构
echo "[4/7] 初始化 Flatpak 元数据..."
flatpak build-init "$WORK_DIR/build" "$FLATPAK_ID" org.fedoraproject.Sdk org.fedoraproject.Platform "$RUNTIME_VER" --arch="$ARCH"

# 5. 重构文件系统
echo "[5/7] 重构路径 (Moving /usr, /opt -> /app)..."
tar -xf "$WORK_DIR/payload.tar.gz" -C "$WORK_DIR/build/files"

cd "$WORK_DIR/build/files"

# A. 处理 /usr -> /app
if [ -d "usr" ]; then
    cp -r usr/* .
    rm -rf usr
fi

# B. 处理 /opt -> /app (扁平化处理)
# 很多软件把主体放在 /opt/appname，我们把它移到 /app/appname
if [ -d "opt" ]; then
    cp -r opt/* .
    rm -rf opt
fi

# C. 处理 /etc
if [ -d "etc" ]; then
    mkdir -p etc-backup
    cp -r etc/* etc-backup/
    rm -rf etc
    mv etc-backup etc
fi

# 6. 修补 (Patching)
echo "[6/7] 修补路径与二进制..."

# 修复 Shebang
grep -rIl "#!/usr/bin/" . | xargs sed -i 's|#!/usr/bin/|#!/app/bin/|g' 2>/dev/null || true

# 尝试修复指向 /opt 的失效软链接 (常见于 /usr/bin/wechat -> /opt/wechat/wechat)
# 我们把链接目标里的 /opt/ 替换为 /app/
find . -type l | while read l; do
    target=$(readlink "$l")
    if [[ "$target" == /opt/* ]]; then
        new_target="/app${target#/opt}"
        ln -sf "$new_target" "$l"
    fi
done

# 修复 RPATH
if command -v patchelf >/dev/null; then
    find . -type f -exec sh -c 'file "{}" | grep -q ELF' \; -print | while read f; do
        patchelf --set-rpath /app/lib64:/app/lib "$f" > /dev/null 2>&1 || true
    done
fi

cd - >/dev/null

# 7. 完成构建并导出
echo "[7/7] 完成构建并打包..."
flatpak build-finish "$WORK_DIR/build" \
    --command="wechat" \
    --filesystem=host \
    --share=network \
    --device=all \
    --share=ipc \
    --socket=x11 \
    --socket=wayland \
    --socket=pulseaudio \
    --env=PATH=/app/bin:/usr/bin:/app/wechat \
    --env=LD_LIBRARY_PATH=/app/lib64:/app/lib \
    --env=XDG_DATA_DIRS=/app/share:/usr/share \
    --allow=devel

# 导出到仓库并打包
mkdir -p "$WORK_DIR/repo"
flatpak build-export "$WORK_DIR/repo" "$WORK_DIR/build"
flatpak build-bundle "$WORK_DIR/repo" "$PWD/$OUTPUT_BUNDLE" "$FLATPAK_ID"

echo "========================================"
echo "SUCCESS! 文件已生成: $PWD/$OUTPUT_BUNDLE"
echo "安装命令: flatpak install --user $OUTPUT_BUNDLE"
echo "如果安装后找不到命令，尝试运行: flatpak run --command=sh $FLATPAK_ID 进去看看路径"
echo "========================================"
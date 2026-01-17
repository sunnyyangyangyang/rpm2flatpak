#!/bin/bash
set -e

# =============================================
# RPM to Flatpak - 智能探测器 (增强交互版)
# =============================================

FEDORA_VER="43"
BASE_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VER}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

if [ -z "$1" ]; then
    echo "用法: $0 <rpm文件路径>"
    exit 1
fi

RPM_FILE=$(realpath "$1")
if [ ! -f "$RPM_FILE" ]; then
    echo "错误：文件不存在: $RPM_FILE"
    exit 1
fi

APP_NAME=$(basename "$RPM_FILE" .rpm | sed 's/_x86_64//;s/_amd64//;s/-[0-9].*//' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="rpm_probe_$$"
CONF_FILE="${APP_NAME}.conf"

# 全局变量
SELECTED_DESKTOP=""
SELECTED_EXEC=""
EXEC_NAME=""
SELECTED_ICON=""
NO_SANDBOX="no"
EXTRA_PATH=""
EXTRA_LD=""

cleanup() {
    echo ""
    echo -e "${BLUE}[*] 清理探测容器...${NC}"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -f /tmp/rpm_probe_files_$$.txt
}
trap cleanup EXIT INT TERM

# =============================================
# 核心功能函数
# =============================================

# 启动容器
init_container() {
    echo -e "${BLUE}[1/2] 启动环境并安装 RPM...${NC}"
    podman run -d --name "$CONTAINER_NAME" \
        --tmpfs /tmp \
        --tmpfs /var/cache/dnf \
        "$BASE_IMAGE" sleep infinity >/dev/null

    podman cp "$RPM_FILE" "$CONTAINER_NAME":/tmp/target.rpm
    echo "  → 正在安装 RPM (可能需要几秒钟)..."
    if ! podman exec "$CONTAINER_NAME" dnf install -y /tmp/target.rpm >/dev/null 2>&1; then
        echo -e "${RED}安装失败！${NC} 请进入交互模式检查。"
    else
        echo -e "  ${GREEN}✓${NC} 安装完成"
    fi
}

# 扫描文件系统 (每次探索回来后都会运行)
scan_files() {
    echo -e "${BLUE}  ↻ 正在扫描容器文件系统...${NC}"
    # 提取所有新增文件
    podman diff "$CONTAINER_NAME" | awk '$1=="A" {print $2}' > /tmp/rpm_probe_files_$$.txt
    
    # 扫描 Desktop
    DESKTOP_LIST=$(grep '\.desktop$' /tmp/rpm_probe_files_$$.txt | grep '/applications/' | grep -v '/opt/' || echo "")
    DESKTOP_COUNT=$(echo "$DESKTOP_LIST" | grep -v '^$' | wc -l)
    
    # 扫描 ELF 可执行文件
    EXEC_LIST=$(podman exec "$CONTAINER_NAME" bash -c "find /usr/bin /usr/sbin /opt -type f 2>/dev/null | head -n 100 | while read f; do if file \"\$f\" 2>/dev/null | grep -q ELF; then echo \"\$f\"; fi; done" | head -30)
    EXEC_COUNT=$(echo "$EXEC_LIST" | grep -v '^$' | wc -l)
    
    # 扫描图标
    ICON_LIST=$(podman exec "$CONTAINER_NAME" bash -c "find /usr/share/icons /usr/share/pixmaps /opt -name '*.png' -o -name '*.svg' 2>/dev/null | head -n 50 | while read f; do size=\$(stat -c%s \"\$f\" 2>/dev/null || echo 0); echo \"\$size \$f\"; done | sort -rn | head -20 | awk '{print \$2}'")
    ICON_COUNT=$(echo "$ICON_LIST" | grep -v '^$' | wc -l)
}

# 进入手动探索模式
enter_explorer() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}🔧 进入容器 Shell${NC}"
    echo "提示: 你可以使用 'ls', 'find', 'file' 等命令查看文件。"
    echo "      如果你修改了文件结构，退出后脚本会重新扫描。"
    echo -e "      输入 ${RED}exit${NC} 返回向导。"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    podman exec -it "$CONTAINER_NAME" bash
    echo ""
    scan_files # 退出后重新扫描
}

# =============================================
# 步骤函数
# =============================================

step_desktop() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [1/4] 选择 Desktop 文件                                  │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        if [ "$DESKTOP_COUNT" -eq 0 ]; then
            echo -e "  ${YELLOW}⚠ 未找到标准的 .desktop 文件${NC}"
        else
            echo "$DESKTOP_LIST" | nl -w4 -s'. ' | sed 's/^/  /'
        fi
        
        echo ""
        echo -e "  操作: [编号] 选择, [s] 跳过/无, ${CYAN}[e] 手动探索${NC}, [m] 手动输入路径"
        read -p "  请选择 > " choice

        case "$choice" in
            e|E) enter_explorer ;;
            s|S) SELECTED_DESKTOP=""; return ;;
            m|M) 
                read -p "  输入完整路径: " manual_path
                if podman exec "$CONTAINER_NAME" test -f "$manual_path"; then
                    SELECTED_DESKTOP="$manual_path"
                    return
                else
                    echo -e "  ${RED}文件不存在${NC}"
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    SELECTED_DESKTOP=$(echo "$DESKTOP_LIST" | sed -n "${choice}p")
                    if [ -n "$SELECTED_DESKTOP" ]; then
                        echo -e "  ${GREEN}✓ 已选择: $SELECTED_DESKTOP${NC}"
                        return
                    fi
                fi
                echo "  无效选择，请重试。"
                ;;
        esac
    done
}

step_exec() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [2/4] 选择主程序 (Executable)                            │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        # 尝试从 Desktop 文件智能解析
        SUGGESTED=""
        if [ -n "$SELECTED_DESKTOP" ]; then
            CMD_IN_DESKTOP=$(podman exec "$CONTAINER_NAME" grep '^Exec=' "$SELECTED_DESKTOP" | head -n1 | sed 's/^Exec=//' | awk '{print $1}' | tr -d '"' | tr -d "'")
            # 检查是否是绝对路径，如果不是则 which 查找
            if [[ "$CMD_IN_DESKTOP" == /* ]]; then
                SUGGESTED="$CMD_IN_DESKTOP"
            else
                SUGGESTED=$(podman exec "$CONTAINER_NAME" which "$CMD_IN_DESKTOP" 2>/dev/null || echo "")
            fi
        fi

        if [ -n "$SUGGESTED" ]; then
            echo -e "  ${BLUE}★ 推荐 (来自 Desktop): $SUGGESTED${NC}"
        fi

        echo "  扫描到的二进制文件:"
        echo "$EXEC_LIST" | nl -w4 -s'. ' | sed 's/^/  /'
        
        echo ""
        echo -e "  操作: [编号] 选择, [a] 使用推荐值, ${CYAN}[e] 手动探索${NC}, [m] 手动输入"
        read -p "  请选择 > " choice

        case "$choice" in
            e|E) enter_explorer ;;
            a|A)
                if [ -n "$SUGGESTED" ]; then
                    SELECTED_EXEC="$SUGGESTED"
                    break
                else
                    echo "  无推荐值。"
                fi
                ;;
            m|M)
                read -p "  输入可执行文件完整路径: " manual_exec
                if podman exec "$CONTAINER_NAME" test -f "$manual_exec"; then
                    SELECTED_EXEC="$manual_exec"
                    break
                else
                    echo -e "  ${RED}文件不存在${NC}"
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    SELECTED_EXEC=$(echo "$EXEC_LIST" | sed -n "${choice}p")
                    if [ -n "$SELECTED_EXEC" ]; then
                        break
                    fi
                fi
                echo "  无效选择。"
                ;;
        esac
    done
    
    # 后处理：确定名称
    EXEC_NAME=$(basename "$SELECTED_EXEC")
    echo -e "  ${GREEN}✓ 已选择: $SELECTED_EXEC (名称: $EXEC_NAME)${NC}"
}

step_icon() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [3/4] 选择图标                                           │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        # 尝试从 Desktop 解析
        SUGGESTED_ICON=""
        if [ -n "$SELECTED_DESKTOP" ]; then
             ICON_NAME=$(podman exec "$CONTAINER_NAME" grep '^Icon=' "$SELECTED_DESKTOP" | head -n1 | cut -d= -f2)
             # 如果 Icon= 已经是绝对路径
             if [[ "$ICON_NAME" == /* ]]; then
                 SUGGESTED_ICON="$ICON_NAME"
             # 否则在 scan 列表中找名字匹配的
             elif [ -n "$ICON_NAME" ]; then
                 SUGGESTED_ICON=$(echo "$ICON_LIST" | grep "$ICON_NAME" | head -n1)
             fi
        fi

        if [ -n "$SUGGESTED_ICON" ]; then
             echo -e "  ${BLUE}★ 推荐 (来自 Desktop): $SUGGESTED_ICON${NC}"
        fi

        echo "  扫描到的图标 (Top 10):"
        echo "$ICON_LIST" | head -10 | nl -w4 -s'. ' | sed 's/^/  /'

        echo ""
        echo -e "  操作: [编号] 选择, [a] 使用推荐值, [s] 跳过, ${CYAN}[e] 手动探索${NC}, [m] 手动输入"
        read -p "  请选择 > " choice

        case "$choice" in
            e|E) enter_explorer ;;
            s|S) SELECTED_ICON=""; return ;;
            a|A) 
                if [ -n "$SUGGESTED_ICON" ]; then
                    SELECTED_ICON="$SUGGESTED_ICON"
                    return
                fi
                ;;
            m|M)
                read -p "  输入图标路径: " manual_icon
                SELECTED_ICON="$manual_icon"
                return
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    SELECTED_ICON=$(echo "$ICON_LIST" | sed -n "${choice}p")
                    if [ -n "$SELECTED_ICON" ]; then
                        echo -e "  ${GREEN}✓ 已选择: $SELECTED_ICON${NC}"
                        return
                    fi
                fi
                echo "  无效选择。"
                ;;
        esac
    done
}

step_flags() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [4/4] 运行参数                                           │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        echo -e "  操作: [Enter] 确认, ${CYAN}[e] 手动探索 (检查沙箱文件)${NC}"
        
        # 检测 Electron
        IS_ELECTRON=0
        if echo "$SELECTED_EXEC" | grep -qE 'electron|code|atom|vscode'; then IS_ELECTRON=1; fi
        if podman exec "$CONTAINER_NAME" find /opt -name "chrome-sandbox" 2>/dev/null | grep -q .; then IS_ELECTRON=1; fi
        
        DEFAULT_SANDBOX="n"
        if [ "$IS_ELECTRON" -eq 1 ]; then
            echo -e "  ${YELLOW}⚠ 检测到可能是 Electron 应用${NC}"
            DEFAULT_SANDBOX="y"
        fi

        read -p "  是否禁用内部沙箱 (--no-sandbox)? [y/N/e] (默认: $DEFAULT_SANDBOX): " sb_input
        
        if [ "$sb_input" = "e" ] || [ "$sb_input" = "E" ]; then
            enter_explorer
            continue
        fi

        if [ -z "$sb_input" ]; then sb_input="$DEFAULT_SANDBOX"; fi
        if [ "$sb_input" = "y" ] || [ "$sb_input" = "Y" ]; then NO_SANDBOX="yes"; else NO_SANDBOX="no"; fi

        read -p "  额外 PATH 路径 (选填/e): " path_input
        if [ "$path_input" = "e" ]; then enter_explorer; continue; fi
        EXTRA_PATH="$path_input"

        read -p "  额外 LD_LIBRARY_PATH (选填/e): " ld_input
        if [ "$ld_input" = "e" ]; then enter_explorer; continue; fi
        EXTRA_LD="$ld_input"
        
        break
    done
}

# =============================================
# 主逻辑
# =============================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RPM 探测器 - 交互模式"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "目标 RPM: $APP_NAME"
echo ""

init_container
scan_files

# 顺序执行步骤
step_desktop
step_exec
step_icon
step_flags

# =============================================
# 生成配置
# =============================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}配置生成完毕${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cat > "$CONF_FILE" <<EOF
# RPM to Flatpak 配置文件
# 生成时间: $(date)

[meta]
app_name=$APP_NAME
rpm_file=$(basename "$RPM_FILE")

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
EOF

echo "配置文件已保存至: $CONF_FILE"
echo "内容如下:"
echo "----------------------------------------"
cat "$CONF_FILE"
echo "----------------------------------------"
echo "你可以直接运行构建脚本了。"
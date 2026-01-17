#!/bin/bash
set -e

# =============================================
# RPM to Flatpak - 智能探测器 (V2.2: 修复信号捕捉)
# =============================================

FEDORA_VER="43"
BASE_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VER}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$1" ]; then
    echo "用法: $0 <rpm文件路径>"
    exit 1
fi

RPM_FILE=$(realpath "$1")
RPM_FILENAME=$(basename "$RPM_FILE")
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
    # 防止重复执行
    trap - EXIT
    
    # 删除临时文件
    if [ -f "/tmp/rpm_probe_files_$$.txt" ]; then
        rm -f "/tmp/rpm_probe_files_$$.txt"
    fi

    # 自动删除容器
    echo ""
    echo -e "${BLUE}[*] 正在清理探测容器...${NC}"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
# 只捕捉 EXIT
trap cleanup EXIT

# ... (中间的辅助函数 scan_files, enter_explorer, init_container 逻辑保持不变，为了篇幅省略，请保留 V2.1 的内容) ...
# 为了方便你复制，这里把 enter_explorer 和 init_container 完整放出来：

scan_files() {
    echo -e "${BLUE}  ↻ 正在扫描容器文件系统...${NC}"
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
    echo -e "${YELLOW}🔧 进入容器 Shell${NC}"
    echo "提示: "
    echo "  1. RPM 文件位于: ${GREEN}/root/$RPM_FILENAME${NC}"
    echo "  2. 强行安装命令: ${CYAN}rpm -ivh --nodeps --nosignature /root/$RPM_FILENAME${NC}"
    echo "  3. 完成后输入 'exit' 返回向导。"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    podman exec -it "$CONTAINER_NAME" bash || true
    
    echo ""
    echo -e "${GREEN}交互模式结束，继续执行...${NC}"
    scan_files
}

init_container() {
    echo -e "${BLUE}[1/2] 启动环境并安装 RPM...${NC}"
    podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    podman run -d --name "$CONTAINER_NAME" \
        --tmpfs /tmp \
        --tmpfs /var/cache/dnf \
        "$BASE_IMAGE" sleep infinity >/dev/null

    echo "  → 上传 RPM 到 /root/$RPM_FILENAME"
    podman cp "$RPM_FILE" "$CONTAINER_NAME":/root/"$RPM_FILENAME"
    
    echo "  → 尝试自动安装..."
    if ! podman exec "$CONTAINER_NAME" dnf install -y "/root/$RPM_FILENAME" >/dev/null 2>&1; then
        echo ""
        echo -e "${RED}❌ 自动安装失败！${NC} (RPM 签名问题或依赖缺失)"
        echo -e "别担心，请按以下步骤手动处理："
        echo -e "1. 输入 ${CYAN}y${NC} 进入容器"
        echo -e "2. 运行: ${CYAN}rpm -ivh --nodeps --nosignature --nodigest /root/$RPM_FILENAME${NC}"
        echo -e "3. 运行: ${CYAN}exit${NC}"
        echo ""
        read -p "是否进入容器手动处理? [Y/n] " fix_choice
        if [[ "$fix_choice" =~ ^[Nn]$ ]]; then
             exit 1
        else
             enter_explorer
        fi
    else
        echo -e "  ${GREEN}✓${NC} 安装完成"
    fi
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
        echo "提示：如果有多个组件 (如 WPS)，请选择主程序的入口。"
        echo ""
        
        if [ "$DESKTOP_COUNT" -eq 0 ]; then
            echo -e "  ${YELLOW}⚠ 未找到标准的 .desktop 文件${NC}"
        else
            echo "$DESKTOP_LIST" | nl -w4 -s'. ' | sed 's/^/  /'
        fi
        
        echo ""
        echo -e "  操作: [编号] 选择, [s] 跳过/无, ${CYAN}[e] 手动探索${NC}, [m] 手动输入路径"
        read -p "  请选择 > " choice

        # 处理 Ctrl+D 或空输入导致的异常
        if [ $? -ne 0 ]; then exit 1; fi

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
        
        SUGGESTED=""
        if [ -n "$SELECTED_DESKTOP" ]; then
            CMD_IN_DESKTOP=$(podman exec "$CONTAINER_NAME" grep '^Exec=' "$SELECTED_DESKTOP" | head -n1 | sed 's/^Exec=//' | awk '{print $1}' | tr -d '"' | tr -d "'")
            # WPS 特殊处理：它的 Exec 往往是 /usr/bin/wps %f，我们只要路径部分
            CMD_IN_DESKTOP=$(echo "$CMD_IN_DESKTOP" | awk '{print $1}')
            
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
    
    EXEC_NAME=$(basename "$SELECTED_EXEC")
    echo -e "  ${GREEN}✓ 已选择: $SELECTED_EXEC (名称: $EXEC_NAME)${NC}"
}

step_icon() {
    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────────────────┐"
        echo "│ [3/4] 选择图标                                           │"
        echo "└─────────────────────────────────────────────────────────┘"
        
        SUGGESTED_ICON=""
        if [ -n "$SELECTED_DESKTOP" ]; then
             ICON_NAME=$(podman exec "$CONTAINER_NAME" grep '^Icon=' "$SELECTED_DESKTOP" | head -n1 | cut -d= -f2)
             if [[ "$ICON_NAME" == /* ]]; then
                 SUGGESTED_ICON="$ICON_NAME"
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
echo "  RPM 探测器 - 交互模式 (V2.2)"
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
echo ""
echo -e "${YELLOW}下一步:${NC}"
echo "运行构建脚本: ./rpm2flatpak-build.sh $CONF_FILE"

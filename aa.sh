#!/bin/bash
# ========================================
# 1Panel 管理脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# 智能寻找 1pctl 的实际路径
get_cmd_path() {
    if [ -x "/usr/local/bin/1pctl" ]; then
        echo "/usr/local/bin/1pctl"
    elif command -v 1pctl &>/dev/null; then
        echo "1pctl"
    else
        echo ""
    fi
}




# 检查并安装 unzip
check_unzip() {
    if ! command -v unzip >/dev/null 2>&1; then
        echo "⚠️ 未检测到 unzip，正在安装..."
        if [ -f /etc/debian_version ]; then
            apt update && apt install -y unzip
        elif [ -f /etc/redhat-release ]; then
            yum install -y unzip || dnf install -y unzip
        elif [ -f /etc/alpine-release ]; then
            apk add unzip
        else
            echo "❌ 无法识别系统，请手动安装 unzip"
            return 1
        fi
        echo "✅ unzip 安装完成"
    fi
    return 0
}

# 更新拓展App核心逻辑
update_local_apps() {
    local LOCAL_PATH="/opt/1panel/resource/apps/local"
    local ZIP_URL="https://github.com/okxlin/appstore/archive/refs/heads/localApps.zip"
    local BACKUP_DIR="/opt/1panel/resource/apps/backup_$(date +%Y%m%d_%H%M%S)"

    if [ ! -d "$LOCAL_PATH" ]; then
        echo -e "${RED}❌ 未检测到 1Panel 本地应用目录：$LOCAL_PATH${RESET}"
        echo "请确认 1Panel 是否已安装并创建了本地应用目录。"
        return 1
    fi

    if ! check_unzip; then
        echo -e "${RED}❌ 环境缺少 unzip，更新终止${RESET}"
        return 1
    fi

    echo "📦 正在备份本地应用到：$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -rf "$LOCAL_PATH"/* "$BACKUP_DIR"/ 2>/dev/null

    echo "⬇️ 正在下载最新 localApps.zip ..."
    if ! wget -O "$LOCAL_PATH/localApps.zip" "$ZIP_URL"; then
        echo -e "${RED}❌ 下载失败，已终止更新${RESET}"
        return 1
    fi

    if [ ! -f "$LOCAL_PATH/localApps.zip" ]; then
        echo -e "${RED}❌ 未找到下载文件${RESET}"
        return 1
    fi

    echo "📂 正在解压覆盖文件..."
    unzip -o -d "$LOCAL_PATH" "$LOCAL_PATH/localApps.zip" >/dev/null

    echo "⚙️ 正在覆盖应用列表..."
    cp -rf "$LOCAL_PATH/appstore-localApps/apps/"* "$LOCAL_PATH/"

    echo "🧹 清理临时文件..."
    rm -rf "$LOCAL_PATH/appstore-localApps" "$LOCAL_PATH/localApps.zip"

    echo "🔄 正在重启 1Panel..."
    local CMD=$(get_cmd_path)
    if [ -n "$CMD" ]; then
        $CMD restart
        echo -e "${GREEN}✅ 1Panel 已成功重启${RESET}"
    else
        echo -e "${YELLOW}⚠️ 未检测到 1pctl 命令，无法自动重启。请稍后手动重启 1Panel。${RESET}"
    fi

    echo -e "${GREEN}✅ 本地应用拓展更新完成！${RESET}"
    echo "🗂 已备份旧版本到：$BACKUP_DIR"
}


check_cmd() {
    local cmd=$(get_cmd_path)
    if [ -z "$cmd" ]; then
        echo -e "${RED}未检测到 1pctl 命令，请确认 1Panel 已正确安装。若未安装，请选择选项 66${RESET}"
        return 1
    fi
    return 0
}

pause(){
    read -rp "按回车继续..."
}


menu(){
clear
echo -e "${GREEN}======================================${RESET}"
echo -e "${GREEN} ◈    1Panel V1 开心版管理菜单    ◈   ${RESET}"
echo -e "${GREEN}======================================${RESET}"

local REAL_CMD=$(get_cmd_path)

# ----- 状态、版本、端口 强行直读 + 智能解析 -----
if [ -n "$REAL_CMD" ] || [ -d "/opt/1panel" ]; then
    # 1. 进程状态检测
    local process_check=$(ps -ef | grep -E "1panel|1p-" | grep -v grep)
    local docker_check=$(command -v docker &>/dev/null && docker ps | grep -E "1panel|1p-")
    if [ -n "$process_check" ] || [ -n "$docker_check" ]; then
        echo -e "${GREEN}服务状态  :${RESET} ${YELLOW}● 运行中${RESET}"
    else
        echo -e "${GREEN}服务状态  :${RESET} ${RED}○ 已停止${RESET}"
    fi

    # 2. 强读具体版本号
    local ver_info=""
    if [ -n "$REAL_CMD" ]; then
        ver_info=$($REAL_CMD version 2>/dev/null | grep "版本" | awk -F': ' '{print $2}' | tr -d ' \r\n')
    fi
    if [ -z "$ver_info" ] && [ -x "/usr/local/bin/1panel" ]; then
        ver_info=$(/usr/local/bin/1panel -v 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | tr -d ' \r\n')
    fi
    if [ -z "$ver_info" ] && [ -f "/opt/1panel/data/env.sh" ]; then
        ver_info=$(grep "VERSION" /opt/1panel/data/env.sh | awk -F'=' '{print $2}' | tr -d '"\r\n ')
    fi

    if [ -n "$ver_info" ]; then
        [[ "$ver_info" =~ ^v ]] || ver_info="v$ver_info"
        echo -e "${GREEN}当前版本  :${RESET} ${YELLOW}${ver_info}${RESET}"
    else
        echo -e "${GREEN}当前版本  :${RESET} ${YELLOW}v2.1.13${RESET}"
    fi

    local port=""
    local entrance=""
    
    if [ -n "$REAL_CMD" ]; then
        # 直接通过官方命令获取完整信息
        local user_info=$($REAL_CMD user-info 2>/dev/null)
        
        # 精准匹配 "面板地址: http://...:端口/" 里的数字
        port=$(echo "$user_info" | grep -oE "http://[^:]+:[0-9]+" | awk -F':' '{print $NF}' | tr -d ' \r\n ')
        
        # 顺便精准提取安全入口（如果有的话）
        entrance=$(echo "$user_info" | grep -oE "http://[^/]+/[A-Za-z0-9]+" | awk -F'/' '{print $NF}' | tr -d ' \r\n ')
    fi
    
    # 兜底方案：如果上面没抓到，再去读 env.sh 配置文件
    if [ -z "$port" ] && [ -f "/opt/1panel/data/env.sh" ]; then
        port=$(grep "1PANEL_PORT" /opt/1panel/data/env.sh | awk -F'=' '{print $2}' | tr -d '"\r\n ')
    fi
    
    # 最终显示，彻底干掉不准的默认值和 netstat 瞎猜
    echo -e "${GREEN}面板端口  :${RESET} ${YELLOW}${port:-5556}${RESET}"
else
    echo -e "${GREEN}核心状态  :${RESET} ${RED}未安装${RESET}"
fi
echo -e "${GREEN}======================================${RESET}"

# ----- 菜单选项列表 (一行显示两个，完全对齐) -----
echo -e "${GREEN} 1.启动服务${RESET}        ${GREEN}|${RESET} ${GREEN} 2.停止服务${RESET}"
echo -e "${GREEN} 3.重启服务${RESET}        ${GREEN}|${RESET} ${GREEN} 4.修改用户名${RESET}"
echo -e "${GREEN} 5.修改密码${RESET}        ${GREEN}|${RESET} ${GREEN} 6.修改面板端口${RESET}"
echo -e "${GREEN}======================================${RESET}"
echo -e "${GREEN} 7.取消安全入口${RESET}    ${GREEN}|${RESET} ${GREEN} 8.取消HTTPS登录${RESET}"
echo -e "${GREEN} 9.取消IP限制${RESET}      ${GREEN}|${RESET} ${GREEN}10.取消两步验证${RESET}"
echo -e "${GREEN}11.取消域名绑定${RESET}    ${GREEN}|${RESET} ${GREEN}12.监听 IPv4${RESET}"
echo -e "${GREEN}13.监听 IPv6${RESET}       ${GREEN}|${RESET} ${GREEN}14.用户信息${RESET}"
echo -e "${YELLOW}15.拓展App商店${RESET}    ${GREEN}|${RESET} ${YELLOW}16.更新 1Panel${RESET}"
echo -e "${GREEN}======================================${RESET}"
echo -e "${YELLOW}66.安装 1Panel${RESET}     ${GREEN}${RESET} ${RED}77.卸载 1Panel${RESET}"
echo -e "${GREEN}======================================${RESET}"
echo -e "${GREEN} 0.退出${RESET}"
}

while true
do
    menu
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r num

    CMD=$(get_cmd_path)

    case "$num" in
    1) if check_cmd; then $CMD start all; fi; sleep 1.5 ;;
    2) if check_cmd; then $CMD stop all; fi; sleep 1.5 ;;
    3) if check_cmd; then $CMD restart all; fi; sleep 1.5 ;;
    4) if check_cmd; then $CMD update username ; fi; pause ;;
    5) if check_cmd; then $CMD update password ; fi; pause ;;
    6) if check_cmd; then $CMD update port ; fi; pause ;;
    7) if check_cmd; then $CMD reset entrance; fi; pause ;;
    8) if check_cmd; then $CMD reset https; fi; pause ;;
    9) if check_cmd; then $CMD reset ips; fi; pause ;;
    10) if check_cmd; then $CMD reset mfa; fi; pause ;;
    11) if check_cmd; then $CMD reset domain; fi; pause ;;
    12) if check_cmd; then $CMD listen-ip ipv4; fi; pause ;;
    13) if check_cmd; then $CMD listen-ip ipv6; fi; pause ;;
    14) if check_cmd; then $CMD user-info; fi; pause ;;
    15) update_local_apps; pause ;;
    77) if check_cmd; then $CMD uninstall; fi; pause ;;
    66)
       echo -e "${GREEN}正在安装部署 1Panel v1 开心版...${RESET}"
       curl -sSL https://resource.1panel.sb/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh
       pause
       ;;
    16)
        echo -e "${GREEN}正在更新...${RESET}"
        curl https://resource.1panel.sb/1panel/package/update.sh | bash
        pause
        ;;
    0) exit ;;
    *) echo -e "${RED}无效选项${RESET}"; sleep 1 ;;
    esac
done

#!/bin/bash
# =================================================================
# java_oci_manage (rbot) 原生脚本管理面板
# =================================================================

# 颜色
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

APP_NAME="java_oci_manage"
BASE_DIR="/opt/rbot"
SCRIPT_FILE="$BASE_DIR/sh_client_bot.sh"
CONFIG_FILE="$BASE_DIR/client_config"

# 检测基础依赖
check_dependencies() {
    if ! command -v wget &> /dev/null; then
        echo -e "${RED}错误: 未检测到 wget，请先安装 wget！${RESET}"
        exit 1
    fi
}


# 动态获取 systemd 服务/进程状态与端口
get_status_info() {
    # 1. 优先通过 systemd 检查状态，再兜底传统进程
    if systemctl is-active --quiet client_bot 2>/dev/null || systemctl is-active --quiet radiance-bot 2>/dev/null || ps aux | grep -E "client_bot|sh_client_bot" | grep -v "grep" &>/dev/null; then
        status="${YELLOW}运行中${RESET}"
        
        # 提取当前运行的端口（优先从 systemd 属性或网络监听中获取）
        webui_port=$(ss -tuln 2>/dev/null | grep -E 'client_bot|java' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
        [[ -z "$webui_port" ]] && webui_port=$(netstat -tuln 2>/dev/null | grep -E 'client_bot|java' | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
        [[ -z "$webui_port" ]] && webui_port=$(ps aux | grep -E "sh_client_bot|client_bot" | grep -v "grep" | awk '{print $NF}' | grep -E '^[0-9]+$')
        [[ -z "$webui_port" ]] && webui_port="9527"
    else
        if [[ -f "$SCRIPT_FILE" ]]; then
            status="${RED}已停止${RESET}"
            webui_port="9527"
        else
            status="${RED}未部署${RESET}"
            webui_port="N/A"
        fi
    fi

    # 2. 检查安装状态
    if [[ -f "$SCRIPT_FILE" ]]; then
        img_version="${GREEN}已安装 (Systemd 守护)${RESET}"
    else
        img_version="${RED}未安装${RESET}"
    fi
}

# 获取公网 IP (兼容双栈环境)
get_public_ip() {
    local mode=${1:-"auto"}
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 部署 / 安装 java_oci_manage
install_utils() {
    check_dependencies
    
    # 创建规范的安装目录
    mkdir -p "$BASE_DIR"
    cd "$BASE_DIR" || exit

    echo -e "${CYAN}====== 自定义参数配置 ======${RESET}"
    echo -ne "${YELLOW}请输入客户端访问端口 [默认: 9527]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9527"
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 端口必须是纯数字！${RESET}"
        return
    fi

    echo -e "${YELLOW}正在下载官方最新版管理脚本...${RESET}"
    wget -O "$SCRIPT_FILE" https://github.com/semicons/java_oci_manage/releases/latest/download/sh_client_bot.sh
    if [[ ! -f "$SCRIPT_FILE" ]]; then
        echo -e "${RED}错误: 脚本下载失败，请检查网络或 GitHub 连通性！${RESET}"
        return
    fi
    chmod +x "$SCRIPT_FILE"

    echo -e "${YELLOW}正在启动客户端 (端口: ${custom_port})...${RESET}"
    bash "$SCRIPT_FILE" "$custom_port"

    echo -e "${YELLOW}等待服务初始化 (约3秒)...${RESET}"
    sleep 3

    DETECT_IP=$(get_public_ip)

    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${GREEN}    java_oci_manage (rbot) 部署成功！        ${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${YELLOW}服务访问地址   : https://${DETECT_IP}:${custom_port}${RESET}"
    echo -e "${RED}特别提示       : 请使用 HTTPS 协议访问，忽略浏览器安全警告即可${RESET}"
    echo -e "${YELLOW}配置文件路径   : $CONFIG_FILE${RESET}"
    echo -e "${YELLOW}私钥存放推荐目录: $BASE_DIR${RESET}"
    echo -e "${GREEN}=============================================${RESET}"
    echo -e "${CYAN}请注意：首次启动页面顶部会有红色未激活提示，请按提示激活！${RESET}"
}

# 更新客户端
update_utils() {
    if [[ ! -f "$SCRIPT_FILE" ]]; then
        echo -e "${RED}错误: 未检测到管理脚本，请先执行选项 1 进行部署！${RESET}"
        return
    fi
    echo -e "${YELLOW}正在升级客户端到最新版本...${RESET}"
    cd "$BASE_DIR" && bash "$SCRIPT_FILE" upgrade
    echo -e "${GREEN}升级操作执行完成。${RESET}"
}

# 卸载客户端
uninstall_utils() {
    echo -ne "${YELLOW}确定要卸载 java_oci_manage 客户端吗？(y/n): ${RESET}"
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if [ -f "$SCRIPT_FILE" ]; then
            cd "$BASE_DIR" && bash "$SCRIPT_FILE" uninstall
            echo -e "${GREEN}官方卸载脚本执行完毕。${RESET}"
            echo -ne "${YELLOW}是否同时删除本地配置及所有私钥文件（/opt/rbot）？(y/n): ${RESET}"
            read -r clean_data
            if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
                rm -rf "$BASE_DIR"
                echo -e "${GREEN}配置及整个数据目录已彻底清理。${RESET}"
            fi
        else
            echo -e "${RED}未找到卸载脚本，清理结束。${RESET}"
        fi
        echo -e "${GREEN}卸载完成！${RESET}"
    fi
}

# 控制命令
start_utils() {
    if [[ ! -f "$SCRIPT_FILE" ]]; then echo -e "${RED}错误: 未安装服务！${RESET}"; return; fi
    echo -ne "${YELLOW}请输入启动端口 [默认: 9527]: ${RESET}"
    read -r custom_port
    [[ -z "$custom_port" ]] && custom_port="9527"
    cd "$BASE_DIR" && bash "$SCRIPT_FILE" "$custom_port"
    echo -e "${GREEN}服务已尝试启动。${RESET}"
}

stop_utils() {
    if [[ ! -f "$SCRIPT_FILE" ]]; then echo -e "${RED}错误: 未安装服务！${RESET}"; return; fi
    cd "$BASE_DIR" && bash "$SCRIPT_FILE" stop
    echo -e "${YELLOW}服务已停止。${RESET}"
}

restart_utils() {
    if [[ ! -f "$SCRIPT_FILE" ]]; then echo -e "${RED}错误: 未安装服务！${RESET}"; return; fi
    cd "$BASE_DIR" && bash "$SCRIPT_FILE" restart
    echo -e "${GREEN}服务已重启。${RESET}"
}

logs_utils() {
    if [[ ! -f "$SCRIPT_FILE" ]]; then echo -e "${RED}错误: 未安装服务！${RESET}"; return; fi
    echo -e "${CYAN}正在查看实时日志（按 Ctrl+C 退出）...${RESET}"
    cd "$BASE_DIR" && bash "$SCRIPT_FILE" log
}

show_info() {
    get_status_info
    DETECT_IP=$(get_public_ip)
    echo -e "${GREEN}================================${RESET}"
    echo -e "${YELLOW}当前状态       : $status"
    echo -e "${YELLOW}程序版本       : ${img_version}${RESET}"
    echo -e "${YELLOW}服务访问地址   : https://${DETECT_IP}:${webui_port}${RESET}"
    echo -e "${YELLOW}配置文件路径   : ${CONFIG_FILE}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${CYAN}--- 当前 client_config 简要内容 ---${RESET}"
        grep -E '^username|^password|^oci' "$CONFIG_FILE" 2>/dev/null || echo "[暂未写入配置数据]"
        echo -e "${GREEN}================================${RESET}"
    fi
}

menu() {
    clear
    get_status_info
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}     ◈  R 探长 管理面板  ◈     ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态 :${RESET} $status"
    echo -e "${GREEN}端口 :${RESET} ${YELLOW}${webui_port}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}1. 部署启动${RESET}"
    echo -e "${GREEN}2. 更新服务${RESET}"
    echo -e "${GREEN}3. 卸载服务${RESET}"
    echo -e "${GREEN}4. 启动服务${RESET}"
    echo -e "${GREEN}5. 停止服务${RESET}"
    echo -e "${GREEN}6. 重启服务${RESET}"
    echo -e "${GREEN}7. 查看日志${RESET}"
    echo -e "${GREEN}8. 查看配置${RESET}"
    echo -e "${GREEN}0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -ne "${GREEN}请输入选项: ${RESET}"
    read -r choice
    case "$choice" in
        1) install_utils ;;
        2) update_utils ;;
        3) uninstall_utils ;;
        4) start_utils ;;
        5) stop_utils ;;
        6) restart_utils ;;
        7) logs_utils ;;
        8) show_info ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
}

while true; do
    menu
    echo -ne "${YELLOW}按回车键继续...${RESET}"
    read -r
done

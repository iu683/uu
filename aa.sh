#!/bin/bash

# ==========================================
# OpenClaw 一键菜单管理脚本
# ==========================================

# ===== 颜色 =====
GREEN="\033[32m"
YELLOW="\033[33m"
GRAY="\033[90m"
RED="\033[31m"
RESET="\033[0m"

CONFIG_FILE="$HOME/.openclaw/openclaw.json"

# ==========================================
# 状态检测
# ==========================================

get_install_status() {
    if command -v openclaw >/dev/null 2>&1; then
        echo -e "${GREEN}已安装${RESET}"
    else
        echo -e "${YELLOW}未安装${RESET}"
    fi
}

get_running_status() {
    if pgrep -f openclaw-gateway >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${RESET}"
    else
        echo -e "${YELLOW}未运行${RESET}"
    fi
}


# ==========================================
# 菜单
# ==========================================

show_menu() {
    clear
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN}     OpenClaw管理菜单           ${RESET}"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${YELLOW}安装状态:${RESET} $(get_install_status)"
    echo -e "${YELLOW}运行状态:${RESET} $(get_running_status)"
    echo -e "${GREEN}==============================${RESET}"
    echo -e "${GREEN} 1. 安装${RESET}"
    echo -e "${GREEN} 2. 启动${RESET}"
    echo -e "${GREEN} 3. 停止${RESET}"
    echo -e "${GREEN} 4. 查看状态${RESET}"
    echo -e "${GREEN} 5. 机器人连接${RESET}"
    echo -e "${GREEN} 6. 编辑配置文件${RESET}"
    echo -e "${GREEN} 7. 初始化向导${RESET}"
    echo -e "${GREEN} 8. 健康检测${RESET}"
    echo -e "${GREEN} 9. WebUI访问地址${RESET}"
    echo -e "${GREEN}10. 更新${RESET}"
    echo -e "${GREEN}11. 卸载${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    printf "${GREEN} 请输入选项: ${RESET}"
}

# ==========================================
# 控制函数
# ==========================================

restart_gateway() {
    openclaw gateway stop >/dev/null 2>&1
    sleep 1
    openclaw gateway start
    sleep 2
}

install_node() {
    if command -v apt >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
        apt install -y nodejs build-essential
    fi
}

install_app() {
    echo "正在安装 OpenClaw..."
    install_node
    npm install -g openclaw@latest
    openclaw onboard --install-daemon
    restart_gateway
    read -p "完成，回车继续..."
}

start_app() {
    restart_gateway
    read -p "已启动，回车继续..."
}

stop_app() {
    openclaw gateway stop
    read -p "已停止，回车继续..."
}

view_status() {
    openclaw status
    openclaw gateway status
    openclaw logs
    read -p "回车继续..."
}

# ==========================================
# 机器人对接
# ==========================================

change_tg_bot_code() {

    while true; do
        clear
        echo -e "${GREEN}==================================${RESET}"
        echo -e "${GREEN}         机器人连接对接              ${RESET}"
        echo -e "${GREEN}==================================${RESET}"
        echo -e "${GREEN}1.Telegram  机器人对接${RESET}"
        echo -e "${GREEN}2.飞书(Lark)机器人对接${RESET}"
        echo -e "${GREEN}3.WhatsApp  机器人对接${RESET}"
        echo -e "${GREEN}0.返回主菜单${RESET}"
        read -r -p $'\033[32m请输入你的选择: \033[0m' bot_choice

        case $bot_choice in
            1)
                read -p "请输入TG机器人收到的连接码 (例如 NYA99R2F)： " code
                [ -z "$code" ] && echo "连接码不能为空" && sleep 1 && continue
                openclaw pairing approve telegram "$code"
                read -p "完成，回车继续..."
                ;;
            2)
                read -p "请输入飞书机器人连接码： " code
                [ -z "$code" ] && echo "连接码不能为空" && sleep 1 && continue
                openclaw pairing approve feishu "$code"
                read -p "完成，回车继续..."
                ;;
            3)
                read -p "请输入WhatsApp连接码： " code
                [ -z "$code" ] && echo "连接码不能为空" && sleep 1 && continue
                openclaw pairing approve whatsapp "$code"
                read -p "完成，回车继续..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}无效选项${RESET}"
                sleep 1
                ;;
        esac
    done
}

show_webui() {

     if ! pgrep -f openclaw-gateway >/dev/null 2>&1; then
        echo -e "${RED}Gateway 未运行${RESET}"
        read -p "回车继续..."
        return
    fi
    
    echo -e "${GREEN}========OpenClaw WebUI 访问地址=============${RESET}"

    local_ip="127.0.0.1"

    token=$(
        openclaw dashboard 2>/dev/null \
        | sed -n 's/.*#token=\([a-z0-9]\+\).*/\1/p' \
        | head -n 1
    )

    echo
    echo -e "${GREEN}本机地址：${RESET}"
    echo
    echo -e "${YELLOW}http://${local_ip}:18789/#token=${token}${RESET}"
    echo
    read -p "回车继续..."
}

update_app() {
    npm install -g openclaw@latest
    restart_gateway
    read -p "更新完成，回车继续..."
}

uninstall_app() {
    openclaw uninstall
    npm uninstall -g openclaw
    read -p "卸载完成，回车继续..."
}

# ==========================================
# 主循环
# ==========================================

while true; do
    show_menu
    read choice
    case $choice in
        1) install_app ;;
        2) start_app ;;
        3) stop_app ;;
        4) view_status ;;
        5) change_tg_bot_code ;;
        6) nano "$CONFIG_FILE" && restart_gateway ;;
        7) openclaw onboard --install-daemon ;;
        8) openclaw doctor --fix ;;
        9) show_webui ;;
        10) update_app ;;
        11) uninstall_app ;;
        0) exit ;;
    esac
done

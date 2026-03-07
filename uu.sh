#!/bin/bash

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

SCRIPT_PATH="/usr/local/bin/clean-server"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/uu.sh"
CONFIG_FILE="/etc/clean-server.conf"

# =================== Telegram ===================
# 配置文件可选，格式：
# TG_BOT_TOKEN="xxxx"
# TG_CHAT_ID="xxxx"
# SERVER_NAME="hostname"
[ -f "$CONFIG_FILE" ] && source $CONFIG_FILE

send_tg() {
    [ -z "$TG_BOT_TOKEN" ] && return
    [ -z "$TG_CHAT_ID" ] && return

    SERVER_NAME=${SERVER_NAME:-$(hostname)}
    MESSAGE="$1"
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # 使用 Markdown 格式，# 标题加粗，模块分割线
    FORMATTED_MSG="*[$SERVER_NAME] 服务器清理通知*\n"
    FORMATTED_MSG+="\`时间: $TIMESTAMP\`\n"
    FORMATTED_MSG+="--------------------------------\n"
    FORMATTED_MSG+="$MESSAGE\n"
    FORMATTED_MSG+="--------------------------------\n"
    FORMATTED_MSG+="_清理由 clean-server 自动执行_"

    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$FORMATTED_MSG" \
        -d parse_mode="Markdown" >/dev/null
}

set_telegram() {
    echo -e "${GREEN}=== Telegram 设置 ===${RESET}"
    read -p "请输入 Telegram Bot Token (留空跳过): " TG_BOT_TOKEN
    read -p "请输入 Telegram Chat ID (留空跳过): " TG_CHAT_ID
    read -p "请输入服务器名称 (留空使用 hostname): " SERVER_NAME
    [ -z "$SERVER_NAME" ] && SERVER_NAME=$(hostname)
    cat > $CONFIG_FILE <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"
EOF
    echo -e "${GREEN}配置已保存${RESET}"
}

# =================== 清理函数 ===================
clean_logs() {
    echo -e "${YELLOW}清理系统日志 /var/log...${RESET}"
    find /var/log -type f -name "*.log" -mtime +7 -delete 2>/dev/null
}

clean_journal() {
    if command -v journalctl >/dev/null 2>&1; then
        echo -e "${YELLOW}清理 systemd 日志...${RESET}"
        journalctl --vacuum-time=7d >/dev/null 2>&1
    else
        echo "系统没有 journalctl"
    fi
}

clean_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "未安装 Docker"
        return
    fi

    echo -e "${YELLOW}清理 Docker 日志...${RESET}"
    find /var/lib/docker/containers/ -name "*-json.log" -size +50M -exec truncate -s 0 {} \; 2>/dev/null

    echo -e "${YELLOW}清理未使用的镜像...${RESET}"
    docker image prune -af >/dev/null 2>&1

    echo -e "${YELLOW}清理未使用的卷...${RESET}"
    docker volume prune -f >/dev/null 2>&1

    echo -e "${YELLOW}清理未使用的网络...${RESET}"
    docker network prune -f >/dev/null 2>&1

    echo -e "${GREEN}Docker 清理完成${RESET}"
}

clean_tmp() {
    echo -e "${YELLOW}清理 /tmp 临时文件...${RESET}"
    find /tmp -type f -mtime +3 -delete 2>/dev/null
}

clean_cache() {
    echo -e "${YELLOW}清理系统缓存...${RESET}"
    command -v apt >/dev/null 2>&1 && apt clean
    command -v apk >/dev/null 2>&1 && apk cache clean
}

run_all() {
    STATUS=""

    echo -e "${GREEN}开始清理服务器...${RESET}"

    clean_logs
    STATUS+="✅ 系统日志清理完成\n"

    clean_journal
    STATUS+="✅ systemd 日志清理完成\n"

    clean_docker
    STATUS+="✅ Docker 日志及资源清理完成\n"

    clean_tmp
    STATUS+="✅ /tmp 文件清理完成\n"

    clean_cache
    STATUS+="✅ 系统缓存清理完成\n"

    echo -e "${GREEN}清理完成${RESET}"

    # 发送 Telegram 美化消息
    send_tg "$STATUS"
}

# =================== cron ===================
enable_cron() {
    echo -e "${GREEN}选择更新频率：${RESET}"
    echo -e "${GREEN}1) 每天${RESET}"
    echo -e "${GREEN}2) 每周${RESET}"
    echo -e "${GREEN}3) 每月${RESET}"
    echo -e "${GREEN}4) 每6小时${RESET}"
    echo -e "${GREEN}5) 自定义 cron 表达式${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " c
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true

    case $c in
        1) echo "0 0 * * * $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        2) echo "0 0 * * 1 $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        3) echo "0 0 1 * * $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        4) echo "0 */6 * * * $SCRIPT_PATH --auto" >> /tmp/cron.tmp ;;
        5)
            echo "示例: 每30分钟 */30 * * * *"
            read -p "请输入完整 cron 表达式: " CRON_EXP
            echo "$CRON_EXP $SCRIPT_PATH --auto" >> /tmp/cron.tmp
            ;;
        *)
            echo -e "${YELLOW}无效选项，取消操作${RESET}"
            rm -f /tmp/cron.tmp
            return
            ;;
    esac

    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    echo -e "${GREEN}自动清理已开启${RESET}"
}

disable_cron() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true
    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp
    echo -e "${YELLOW}自动清理已关闭${RESET}"
}

show_cron() {
    echo -e "${GREEN}当前定时任务:${RESET}"
    crontab -l 2>/dev/null | grep "$SCRIPT_PATH --auto"
}

# =================== 脚本管理 ===================
update_script() {
    echo -e "${GREEN}正在更新脚本...${RESET}"
    curl -sL $SCRIPT_URL -o $SCRIPT_PATH
    chmod +x $SCRIPT_PATH
    echo -e "${GREEN}更新完成${RESET}"
}

uninstall_script() {
    echo -e "${RED}正在卸载脚本...${RESET}"
    disable_cron
    rm -f $SCRIPT_PATH
    echo -e "${GREEN}卸载完成${RESET}"
    exit
}

install_script() {
    if [ "$0" != "$SCRIPT_PATH" ]; then
        echo -e "${GREEN}正在安装脚本...${RESET}"
        curl -sL $SCRIPT_URL -o $SCRIPT_PATH
        chmod +x $SCRIPT_PATH
        echo -e "${GREEN}安装完成${RESET}"
        echo -e "${GREEN}运行命令: clean-server${RESET}"
        return
    fi
}

# =================== 菜单 ===================
menu() {
    clear
    echo -e "${GREEN}=== 服务器清理工具 ===${RESET}"
    echo -e "${GREEN} 1) 清理系统日志${RESET}"
    echo -e "${GREEN} 2) 清理 systemd 日志${RESET}"
    echo -e "${GREEN} 3) 清理 Docker 日志和无用资源${RESET}"
    echo -e "${GREEN} 4) 清理 /tmp 文件${RESET}"
    echo -e "${GREEN} 5) 清理系统缓存${RESET}"
    echo -e "${GREEN} 6) 一键全部清理${RESET}"
    echo -e "${GREEN} 7) 开启每日自动清理${RESET}"
    echo -e "${GREEN} 8) 关闭自动清理${RESET}"
    echo -e "${GREEN} 9) 查看定时任务${RESET}"
    echo -e "${GREEN}10) 设置 Telegram 通知${RESET}"
    echo -e "${GREEN}11) 更新脚本${RESET}"
    echo -e "${GREEN}12) 卸载脚本${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"

    read -r -p $'\033[32m请选择: \033[0m' choice
}

# =================== 自动模式 ===================
if [ "$1" = "--auto" ]; then
    run_all
    exit
fi

install_script

# =================== 主循环 ===================
while true; do
    menu
    case $choice in
        1) clean_logs ;;
        2) clean_journal ;;
        3) clean_docker ;;
        4) clean_tmp ;;
        5) clean_cache ;;
        6) run_all ;;
        7) enable_cron ;;
        8) disable_cron ;;
        9) show_cron ;;
        10) set_telegram ;;
        11) update_script ;;
        12) uninstall_script ;;
        0) exit ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac
    read -p "按回车返回菜单..."
done

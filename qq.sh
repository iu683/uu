#!/usr/bin/env bash
set -e

#################################
# 基础路径
#################################
ROOT="/root"
CONF="/etc/toolbox-update.conf"
SCRIPT_PATH="/usr/local/bin/toolbox-manager.sh"

#################################
# 颜色
#################################
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

#################################
# 读取配置
#################################
load_conf() {
    [ -f "$CONF" ] && source "$CONF"
    SERVER_NAME="${SERVER_NAME:-$(hostname)}"
}

#################################
# Telegram（可选）
#################################
tg_send() {
    load_conf
    [ -z "${TG_BOT_TOKEN:-}" ] && return
    [ -z "${TG_CHAT_ID:-}" ] && return

    curl -s -X POST \
      "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d text="$1" \
      -d parse_mode="HTML" >/dev/null 2>&1 || true
}

#################################
# 更新逻辑 + TG通知优化
#################################
update_one() {
    NAME="$1"
    FILE="$2"
    URL="$3"

    if [ ! -f "$ROOT/$FILE" ]; then
        echo -e "${YELLOW}跳过 $NAME（未安装）${RESET}"
        return
    fi

    echo -e "${GREEN}运行 $NAME ...${RESET}"

    # 删除旧文件
    rm -f "$ROOT/$FILE"

    TMP=$(mktemp)

    if curl -fsSL "$URL" -o "$TMP"; then
        chmod +x "$TMP"

        # 自动输入0退出菜单
        if printf "0\n" | bash "$TMP" >/dev/null 2>&1; then
            UPDATED_LIST+=("$NAME")
        fi
    fi

    rm -f "$TMP"
}

run_update() {
    load_conf
    UPDATED_LIST=()

    # 更新各脚本
    update_one "vps-toolbox" "vps-toolbox.sh" \
    "https://raw.githubusercontent.com/Polarisiu/vps-toolbox/main/uu.sh"

    update_one "proxy" "proxy.sh" \
    "https://raw.githubusercontent.com/Polarisiu/proxy/main/proxy.sh"

    update_one "oracle" "oracle.sh" \
    "https://raw.githubusercontent.com/Polarisiu/oracle/main/oracle.sh"

    update_one "store" "store.sh" \
    "https://raw.githubusercontent.com/Polarisiu/app-store/main/store.sh"

    update_one "Alpine" "Alpine.sh" \
    "https://raw.githubusercontent.com/Polarisiu/Alpinetool/main/Alpine.sh"

    # ⭐ Telegram 只在有更新时发送，脚本用空格分隔
    if [ ${#UPDATED_LIST[@]} -gt 0 ]; then
        MSG="🚀 脚本已更新
服务器: ${SERVER_NAME}
脚本: ${UPDATED_LIST[*]}"
        tg_send "$MSG"
        echo -e "${GREEN}更新完成，已发送 TG 通知${RESET}"
    else
        echo -e "${YELLOW}没有脚本需要更新${RESET}"
    fi
}

#################################
# cron 管理
#################################
enable_cron() {
    echo "选择更新频率："
    echo "1) 每天"
    echo "2) 每周"
    echo "3) 每月"
    echo "4) 每6小时"

    read -p "选择: " c

    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true

    case $c in
        1) echo "0 3 * * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        2) echo "0 3 * * 1 $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        3) echo "0 3 1 * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        4) echo "0 */6 * * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
    esac

    crontab /tmp/cron.tmp
    rm -f /tmp/cron.tmp

    echo -e "${GREEN}自动更新已开启${RESET}"
}

disable_cron() {
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" | crontab -
    echo -e "${RED}自动更新已关闭${RESET}"
}

#################################
# Telegram + VPS名称 设置
#################################
tg_setup() {
    read -p "Bot Token: " token
    read -p "Chat ID: " chat
    read -p "VPS 名称(回车默认 hostname): " name
    name="${name:-$(hostname)}"

    cat >"$CONF" <<EOF
TG_BOT_TOKEN="$token"
TG_CHAT_ID="$chat"
SERVER_NAME="$name"
EOF

    echo -e "${GREEN}Telegram 与 VPS 名称已保存${RESET}"
}

#################################
# 自动模式（cron用）
#################################
if [ "${1:-}" = "--auto" ]; then
    run_update
    exit
fi

#################################
# 菜单循环
#################################
while true; do
    clear
    echo -e "${GREEN}=== Toolbox 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 立即更新${RESET}"
    echo -e "${GREEN}2) 开启自动更新(cron)${RESET}"
    echo -e "${GREEN}3) 关闭自动更新${RESET}"
    echo -e "${GREEN}4) Telegram + VPS名称 设置(可选)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) run_update; read -p "回车继续..." ;;
        2) enable_cron; read -p "回车继续..." ;;
        3) disable_cron; read -p "回车继续..." ;;
        4) tg_setup; read -p "回车继续..." ;;
        0) exit ;;
    esac
done

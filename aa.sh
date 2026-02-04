#!/usr/bin/env bash
set -e

#################################
# 基础路径
#################################
ROOT="/root"
SCRIPT_PATH="$ROOT/toolboxupdate.sh"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/aa.sh"
CONF="/etc/toolbox-update.conf"
LOG_FILE="/var/log/toolbox-update.log"
CRON_TAG="# toolbox-auto-update"

#################################
# 颜色
#################################
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

#################################
# 自动下载安装管理器
#################################
if [ ! -f "$SCRIPT_PATH" ]; then
    echo -e "${GREEN}🚀 管理器不存在，正在下载到 $SCRIPT_PATH ...${RESET}"
    curl -sL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 URL${RESET}"
        exit 1
    fi
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 下载完成，脚本已赋权限${RESET}"
fi

#################################
# 读取配置
#################################
load_conf() {
    [ -f "$CONF" ] && source "$CONF"
    SERVER_NAME="${SERVER_NAME:-$(hostname)}"
}

#################################
# Telegram 可选
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
# 更新逻辑
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
    rm -f "$ROOT/$FILE"
    TMP=$(mktemp)

    if curl -fsSL "$URL" -o "$TMP"; then
        chmod +x "$TMP"
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
# cron 管理（支持自定义）
#################################
enable_cron() {
    echo "选择更新频率："
    echo "1) 每天"
    echo "2) 每周"
    echo "3) 每月"
    echo "4) 每6小时"
    echo "5) 自定义 cron 表达式"

    read -p "选择: " c

    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --auto" > /tmp/cron.tmp || true

    case $c in
        1) echo "0 3 * * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        2) echo "0 3 * * 1 $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        3) echo "0 3 1 * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        4) echo "0 */6 * * * $SCRIPT_PATH --auto" >>/tmp/cron.tmp ;;
        5)
            echo "示例: 每30分钟 */30 * * * *"
            read -p "请输入完整 cron 表达式: " CRON_EXP
            echo "$CRON_EXP $SCRIPT_PATH --auto" >>/tmp/cron.tmp
            ;;
        *)
            echo -e "${YELLOW}无效选项，取消操作${RESET}"
            rm -f /tmp/cron.tmp
            return
            ;;
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
# Telegram 设置
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
# 卸载管理器函数
#################################
uninstall_manager() {
    echo -e "${RED}⚠️ 正在卸载管理器...${RESET}"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
    echo -e "${GREEN}✅ 已删除所有定时任务${RESET}"
    [ -f "$SCRIPT_PATH" ] && rm -f "$SCRIPT_PATH" && echo -e "${GREEN}✅ 已删除管理器脚本${RESET}"
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE" && echo -e "${GREEN}✅ 已删除日志 ${LOG_FILE}${RESET}"
    [ -f "$CONF" ] && rm -f "$CONF" && echo -e "${GREEN}✅ 已删除配置文件 ${CONF}${RESET}"
    echo -e "${GREEN}卸载完成${RESET}"
    exit 0
}

#################################
# 自动模式（cron调用）
#################################
if [ "${1:-}" = "--auto" ]; then
    run_update
    exit
fi

#################################
# 删除日志
#################################
delete_log() {
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE"
    echo -e "${RED}日志已删除${RESET}"
}

#################################
# 菜单循环
#################################
while true; do
    clear
    echo -e "${GREEN}=== Toolbox 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 立即更新${RESET}"
    echo -e "${GREEN}2) 开启自动更新(cron)${RESET}"
    echo -e "${GREEN}3) 关闭自动更新${RESET}"
    echo -e "${GREEN}4) 设置 Telegram & 服务器名称(可选)${RESET}"
    echo -e "${GREEN}5) 卸载管理器${RESET}"
    echo -e "${GREEN}6) 删除日志${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) run_update; read -p "回车继续..." ;;
        2) enable_cron; read -p "回车继续..." ;;
        3) disable_cron; read -p "回车继续..." ;;
        4) tg_setup; read -p "回车继续..." ;;
        5) uninstall_manager ;;
        6) delete_log; read -p "回车继续..." ;;
        0) exit ;;
    esac
done

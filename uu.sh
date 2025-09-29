#!/bin/bash

# ================== 基础配置 ==================
SCRIPT_PATH="/opt/vpsw/uuw.sh"
CONFIG_FILE="/opt/vpsw/.vps_ttg_config"
SCRIPT_URL="https://raw.githubusercontent.com/iu683/uu/main/uu.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'
TASK_TAG="#vps_tg_task"
OUTPUT_FILE="/opt/vpsw/tmp/vps_network_info.txt"

# ================== 自动下载脚本 ==================
download_script() {
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 脚本已下载到 $SCRIPT_PATH${RESET}"
}

# ================== 卸载脚本 ==================
uninstall_script() {
    echo -e "${YELLOW}⚠️ 即将卸载 tg.sh 脚本及配置和定时任务${RESET}"
    read -rp "确认卸载吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        crontab -l 2>/dev/null | grep -v "$TASK_TAG" | crontab -
        rm -f "$SCRIPT_PATH" "$CONFIG_FILE" "$OUTPUT_FILE"
        echo -e "${GREEN}✅ 已卸载${RESET}"
        exit 0
    else
        echo "取消卸载"
    fi
}

# ================== Telegram 配置 ==================
setup_telegram() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo "第一次运行，需要配置 Telegram 参数"
        read -rp "Bot Token: " TG_BOT_TOKEN
        read -rp "Chat ID: " TG_CHAT_ID
        echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$CONFIG_FILE"
        echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo "配置已保存。"
    fi
}

modify_config() {
    read -rp "新的 Bot Token: " TG_BOT_TOKEN
    read -rp "新的 Chat ID: " TG_CHAT_ID
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$CONFIG_FILE"
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "✅ 配置已更新"
}

# ================== 收集 VPS 网络信息 ==================
collect_network_info() {
    echo "收集网络信息..."
    {
    echo "================= VPS 网络信息 ================="
    echo "日期: $(date)"
    echo "主机名: $(hostname)"
    echo ""
    echo "=== 系统信息 ==="
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl
    else
        cat /etc/os-release
    fi
    echo ""
    } > "$OUTPUT_FILE"

    echo "=== 网络接口信息 ===" >> "$OUTPUT_FILE"
    for IFACE in $(ls /sys/class/net/); do
        DESC="$IFACE"
        [ "$IFACE" = "lo" ] && DESC="$IFACE (回环接口)"
        [ "$IFACE" != "lo" ] && DESC="$IFACE (主网卡)"
        echo "------------------------" >> "$OUTPUT_FILE"
        echo "接口: $DESC" >> "$OUTPUT_FILE"

        IPV4=$(ip -4 addr show $IFACE | grep -oP 'inet \K[\d./]+')
        [ -n "$IPV4" ] && echo "IPv4: $IPV4" >> "$OUTPUT_FILE" || echo "IPv4: 无" >> "$OUTPUT_FILE"

        IPV6=$(ip -6 addr show $IFACE scope global | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+')
        [ -n "$IPV6" ] && echo "IPv6: $IPV6" >> "$OUTPUT_FILE" || echo "IPv6: 无" >> "$OUTPUT_FILE"

        LL6=$(ip -6 addr show $IFACE scope link | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+')
        [ -n "$LL6" ] && echo "链路本地 IPv6: $LL6" >> "$OUTPUT_FILE"

        MAC=$(cat /sys/class/net/$IFACE/address)
        echo "MAC: $MAC" >> "$OUTPUT_FILE"
    done
    echo "------------------------" >> "$OUTPUT_FILE"

    echo "" >> "$OUTPUT_FILE"
    echo "=== 默认路由 ===" >> "$OUTPUT_FILE"
    echo "IPv4 默认路由:" >> "$OUTPUT_FILE"
    ip route show default >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo "IPv6 默认路由:" >> "$OUTPUT_FILE"
    ip -6 route show default >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    echo "=== 网络连通性测试 ===" >> "$OUTPUT_FILE"
    ping -c 3 8.8.8.8 >> "$OUTPUT_FILE" 2>&1
    ping6 -c 3 google.com >> "$OUTPUT_FILE" 2>&1

    GATEWAY6=$(ip -6 route | grep default | awk '{print $3}')
    if [ -n "$GATEWAY6" ]; then
        ping6 -c 2 $GATEWAY6 >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "IPv6 网关 $GATEWAY6 可达" >> "$OUTPUT_FILE"
        else
            echo "⚠️ IPv6 网关 $GATEWAY6 不可达" >> "$OUTPUT_FILE"
        fi
    fi
}


# ================== 发送到 Telegram ==================
send_to_telegram() {
    source "$CONFIG_FILE"
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        echo "❌ Telegram 配置无效，请先设置"
        return 1
    fi
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$(cat "$OUTPUT_FILE")" >/dev/null
    echo -e "${GREEN}✅ 消息已发送到 Telegram${RESET}"
}

# ================== 定时任务管理 ==================
setup_cron() {
    SCRIPT_PATH="$(readlink -f "$0")"
    CRON_CMD="bash $SCRIPT_PATH --cron $TASK_TAG"
    echo -e "${GREEN}请选择定时任务频率:${RESET}"
    echo "1) 每天 0 点"
    echo "2) 每周一 0 点"
    echo "3) 每月 1 号 0 点"
    echo "4) 取消定时任务"
    read -rp "选择 [1-4]: " choice
    case $choice in
        1) SCHEDULE="0 0 * * *" ;;
        2) SCHEDULE="0 0 * * 1" ;;
        3) SCHEDULE="0 0 1 * *" ;;
        4) crontab -l 2>/dev/null | grep -v "$TASK_TAG" | crontab -
           echo "✅ 已取消定时任务"
           return ;;
        *) echo "无效选择"; return ;;
    esac
    (crontab -l 2>/dev/null | grep -v "$TASK_TAG"; echo "$SCHEDULE $CRON_CMD") | crontab -
    echo "✅ 定时任务已设置: $SCHEDULE"
}

# ================== 菜单 ==================
menu() {
    while true; do
        echo ""
        echo -e "${GREEN}===== VPS Telegram 管理菜单 =====${RESET}"
        echo -e "${GREEN}1) 查看并发送 VPS 网络信息${RESET}"
        echo -e "${GREEN}2) 修改 Telegram 配置${RESET}"
        echo -e "${GREEN}3) 设置/取消定时任务${RESET}"
        echo -e "${GREEN}4) 卸载脚本${RESET}"
        echo -e "${GREEN}5) 退出${RESET}"
        read -rp "请选择操作: " choice
        case $choice in
            1) setup_telegram; collect_network_info; send_to_telegram ;;
            2) modify_config ;;
            3) setup_cron ;;
            4) uninstall_script ;;
            5) exit 0 ;;
            *) echo "无效选择"; read -p "按回车返回菜单..." ;;
        esac
    done
}

# ================== 启动 ==================
if [[ "$1" == "--cron" ]]; then
    setup_telegram
    collect_network_info
    send_to_telegram
    exit 0
fi

download_script
menu

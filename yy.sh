#!/bin/bash
# =========================================
# VPS 网络信息管理脚本（绿色菜单版 + 定时任务 + Telegram 美观消息）
# =========================================

CONFIG_FILE="$HOME/.vps_tg_config"
OUTPUT_FILE="/tmp/vps_network_info.txt"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

# =============================
# 获取 Telegram 参数（首次提示）
# =============================
setup_telegram() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo -e "${YELLOW}第一次运行，需要配置 Telegram 参数${RESET}"
        echo -n "请输入 Telegram Bot Token: "
        read -r TG_BOT_TOKEN
        echo -n "请输入 Telegram Chat ID: "
        read -r TG_CHAT_ID
        echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$CONFIG_FILE"
        echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo -e "${GREEN}配置已保存，下次运行可直接使用。${RESET}"
    fi
}

# =============================
# 修改 Telegram 配置
# =============================
modify_config() {
    echo -e "${YELLOW}修改 Telegram 配置:${RESET}"
    echo -n "请输入新的 Bot Token: "
    read -r TG_BOT_TOKEN
    echo -n "请输入新的 Chat ID: "
    read -r TG_CHAT_ID
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$CONFIG_FILE"
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}配置已更新。${RESET}"
}

# =============================
# 删除临时文件
# =============================
delete_file() {
    if [ -f "$OUTPUT_FILE" ]; then
        rm -f "$OUTPUT_FILE"
        echo -e "${GREEN}文件 $OUTPUT_FILE 已删除。${RESET}"
    else
        echo -e "${YELLOW}文件 $OUTPUT_FILE 不存在。${RESET}"
    fi
}

# =============================
# 收集网络信息
# =============================
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
}

# =============================
# 发送美观信息到 Telegram
# =============================
send_to_telegram() {
    if [ ! -f "$OUTPUT_FILE" ]; then
        echo -e "${YELLOW}⚠️ 文件 $OUTPUT_FILE 不存在，请先收集网络信息。${RESET}"
        return
    fi

    TG_MSG="📡 VPS 网络信息\n===============================\n"
    TG_MSG+="主机名: $(hostname)\n"

    for IFACE in $(ls /sys/class/net/); do
        DESC="$IFACE"
        [ "$IFACE" = "lo" ] && DESC="$IFACE (回环接口)"
        [ "$IFACE" != "lo" ] && DESC="$IFACE (主网卡)"

        IPV4=$(ip -4 addr show $IFACE | grep -oP 'inet \K[\d./]+')
        IPV4=${IPV4:-无}

        IPV6=$(ip -6 addr show $IFACE scope global | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+')
        IPV6=${IPV6:-无}

        LL6=$(ip -6 addr show $IFACE scope link | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+')
        LL6=${LL6:-无}

        MAC=$(cat /sys/class/net/$IFACE/address)

        TG_MSG+="\n接口: $DESC\nIPv4: $IPV4\nIPv6: $IPV6\n链路本地 IPv6: $LL6\nMAC: $MAC\n"
        TG_MSG+="-------------------------------\n"
    done

    # 默认路由
    TG_MSG+="IPv4 默认路由:\n$(ip route show default)\n"
    TG_MSG+="IPv6 默认路由:\n$(ip -6 route show default)\n"
    TG_MSG+="-------------------------------\n"

    # Ping 测试
    PING4=$(ping -c 2 8.8.8.8 | grep 'packet loss' | awk '{print $6 " " $7}')
    PING6=$(ping6 -c 2 google.com | grep 'packet loss' | awk '{print $6 " " $7}')
    TG_MSG+="Ping 8.8.8.8: $PING4\nPing6 google.com: $PING6\n"

    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="\`\`\`$TG_MSG\`\`\`"

    echo -e "${GREEN}信息已发送到 Telegram。${RESET}"
}

# =============================
# 设置定时任务
# =============================
setup_cron() {
    echo -e "${GREEN}===== 设置定时任务 =====${RESET}"
    echo "1) 每天"
    echo "2) 每周"
    echo "3) 每月"
    echo -n "请选择执行周期 [1-3]，按回车返回菜单: "
    read -r cron_choice
    case $cron_choice in
        1) CRON_TIME="0 0 * * *" ;;
        2) CRON_TIME="0 0 * * 0" ;;
        3) CRON_TIME="0 0 1 * *" ;;
        "") echo "返回菜单..."; return ;;
        *) echo -e "${RED}无效选择，返回菜单${RESET}"; return ;;
    esac

    SCRIPT_PATH="$(realpath "$0")"
    # 删除已有 VPS 网络信息任务
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
    # 添加新的定时任务
    (crontab -l 2>/dev/null; echo "$CRON_TIME bash $SCRIPT_PATH --cron") | crontab -
    echo -e "${GREEN}定时任务已设置成功！${RESET}"
    echo "cron 表达式: $CRON_TIME"
}

# =============================
# 支持 --cron 参数，后台执行
# =============================
if [ "$1" == "--cron" ]; then
    setup_telegram
    collect_network_info
    send_to_telegram
    exit 0
fi

# =============================
# 菜单主函数
# =============================
menu() {
    while true; do
        echo ""
        echo -e "${GREEN}===== VPS 网络管理菜单 =====${RESET}"
        echo -e "${GREEN}1) 查看并发送网络信息到 Telegram${RESET}"
        echo -e "${GREEN}2) 修改 Telegram 配置${RESET}"
        echo -e "${GREEN}3) 删除临时文件${RESET}"
        echo -e "${GREEN}4) 设置定时任务（每天/每周/每月）${RESET}"
        echo -e "${GREEN}5) 退出${RESET}"
        echo -ne "${GREEN}请选择操作 [1-5]，按回车刷新菜单: ${RESET}"
        read -r choice
        case $choice in
            1) setup_telegram; collect_network_info; send_to_telegram ;;
            2) modify_config ;;
            3) delete_file ;;
            4) setup_cron ;;
            5) echo -e "${GREEN}退出脚本。${RESET}"; exit 0 ;;
            "") continue ;;
            *) echo -e "${RED}无效选择，请输入 1-5 或按回车刷新菜单。${RESET}" ;;
        esac
    done
}

# =============================
# 启动菜单
# =============================
menu

#!/bin/bash
# =========================================
# VPS 网络信息管理脚本（绿色菜单版 + 定时任务 + 卸载功能）
# =========================================

# ================== 配置 ==================
SCRIPT_PATH="$HOME/vps_network.sh"          # 当前脚本路径
CONFIG_FILE="$HOME/.vps_tg_config"         # Telegram 配置
OUTPUT_FILE="/tmp/vps_network_info.txt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

TASK_TAG="#vps_network_task"

# ================== 下载脚本 ==================
download_script() {
    mkdir -p "$(dirname "$SCRIPT_PATH")"
    curl -sSL "https://raw.githubusercontent.com/your_repo/uuw.sh" -o "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 脚本已下载到 $SCRIPT_PATH${RESET}"
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
        echo -e "${GREEN}配置已保存到 $CONFIG_FILE${RESET}"
        read -p "按回车继续..."
    fi
}

modify_config() {
    echo "修改 Telegram 配置:"
    read -rp "新的 Bot Token: " TG_BOT_TOKEN
    read -rp "新的 Chat ID: " TG_CHAT_ID
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$CONFIG_FILE"
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✅ 配置已更新${RESET}"
    read -p "按回车返回菜单..."
}

# ================== 收集网络信息 ==================
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

        IPV4=$(ip -4 addr show $IFACE | awk '/inet /{print $2}')
        [ -n "$IPV4" ] && echo "IPv4: $IPV4" >> "$OUTPUT_FILE" || echo "IPv4: 无" >> "$OUTPUT_FILE"

        IPV6=$(ip -6 addr show $IFACE scope global | awk '/inet6 /{print $2}')
        [ -n "$IPV6" ] && echo "IPv6: $IPV6" >> "$OUTPUT_FILE" || echo "IPv6: 无" >> "$OUTPUT_FILE"

        LL6=$(ip -6 addr show $IFACE scope link | awk '/inet6 /{print $2}')
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

    GATEWAY6=$(ip -6 route | awk '/default/{print $3}')
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
    if [ ! -f "$OUTPUT_FILE" ]; then
        echo "⚠️ 文件 $OUTPUT_FILE 不存在，请先收集网络信息。"
        read -p "按回车返回菜单..."
        return
    fi
    source "$CONFIG_FILE"
    TG_MSG="📡 VPS 网络信息\`\`\`$(cat $OUTPUT_FILE)\`\`\`"
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d parse_mode="Markdown" \
        -d text="$TG_MSG" >/dev/null
    echo -e "${GREEN}✅ 信息已发送到 Telegram${RESET}"
    rm -f "$OUTPUT_FILE"
    read -p "按回车返回菜单..."
}

# ================== 删除临时文件 ==================
delete_file() {
    if [ -f "$OUTPUT_FILE" ]; then
        rm -f "$OUTPUT_FILE"
        echo -e "${GREEN}✅ 文件 $OUTPUT_FILE 已删除${RESET}"
    else
        echo "文件 $OUTPUT_FILE 不存在。"
    fi
    read -p "按回车返回菜单..."
}

# ================== 定时任务管理 ==================
setup_cron_job(){
  echo -e "${GREEN}===== 定时任务管理 =====${RESET}"
  echo -e "${GREEN}1) 每天发送一次 VPS 信息 (0点)${RESET}"
  echo -e "${GREEN}2) 每周发送一次 VPS 信息 (周一 0点)${RESET}"
  echo -e "${GREEN}3) 每月发送一次 VPS 信息 (1号 0点)${RESET}"
  echo -e "${GREEN}4) 删除当前任务(仅本脚本相关)${RESET}"
  echo -e "${GREEN}5) 查看当前任务${RESET}"
  echo -e "${GREEN}6) 返回菜单${RESET}"
  read -rp "请选择 [1-6]: " cron_choice

  CRON_CMD="bash $SCRIPT_PATH --cron"

  case $cron_choice in
    1) (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 * * * $CRON_CMD") | crontab -
       echo -e "${GREEN}✅ 已设置每天 0 点发送一次 VPS 信息${RESET}" ;;
    2) (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 * * 1 $CRON_CMD") | crontab -
       echo -e "${GREEN}✅ 已设置每周一 0 点发送一次 VPS 信息${RESET}" ;;
    3) (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "0 0 1 * * $CRON_CMD") | crontab -
       echo -e "${GREEN}✅ 已设置每月 1 日 0 点发送一次 VPS 信息${RESET}" ;;
    4) crontab -l 2>/dev/null | grep -v "$CRON_CMD" | crontab -
       echo -e "${RED}❌ 已删除本脚本相关的定时任务${RESET}" ;;
    5) echo -e "${YELLOW}当前已配置的定时任务:${RESET}"
       crontab -l 2>/dev/null | grep "$CRON_CMD" || echo "⚠️ 没有找到和本脚本相关的定时任务" ;;
    6) return ;;
    *) echo -e "${RED}无效选择${RESET}" ;;
  esac
  read -p "按回车返回菜单..."
}

# ================== 卸载脚本 ==================
uninstall_script() {
    echo -e "${YELLOW}⚠️ 即将卸载脚本及清理定时任务${RESET}"
    read -rp "确认卸载吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        crontab -l 2>/dev/null | grep -v "bash $SCRIPT_PATH" | crontab -
        rm -f "$SCRIPT_PATH" "$CONFIG_FILE" "$OUTPUT_FILE"
        echo -e "${GREEN}✅ 脚本已卸载${RESET}"
        exit 0
    else
        echo "取消卸载"
        read -p "按回车返回菜单..."
    fi
}

# ================== 菜单主函数 ==================
menu() {
    while true; do
        echo ""
        echo -e "${GREEN}===== VPS 网络管理菜单 =====${RESET}"
        echo -e "${GREEN}1) 查看并发送网络信息到 Telegram${RESET}"
        echo -e "${GREEN}2) 修改 Telegram 配置${RESET}"
        echo -e "${GREEN}3) 删除临时文件${RESET}"
        echo -e "${GREEN}4) 定时任务管理${RESET}"
        echo -e "${GREEN}5) 卸载脚本${RESET}"
        echo -e "${GREEN}6) 退出${RESET}"
        read -rp "请选择操作 [1-6]: " choice
        case $choice in
            1) setup_telegram; collect_network_info; send_to_telegram ;;
            2) modify_config ;;
            3) delete_file ;;
            4) setup_cron_job ;;
            5) uninstall_script ;;
            6) echo "退出脚本"; exit 0 ;;
            *) echo -e "${RED}无效选择，请输入 1-6${RESET}"; read -p "按回车返回菜单..." ;;
        esac
    done
}

# ================== 支持 --cron 参数 ==================
if [ "$1" == "--cron" ]; then
    setup_telegram
    collect_network_info
    send_to_telegram
    exit 0
fi

# ================== 启动菜单 ==================
menu

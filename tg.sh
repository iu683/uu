#!/bin/bash
# =========================================
# VPS 网络信息收集 + Telegram 推送（美观解析版）
# =========================================

CONFIG_FILE="$HOME/.vps_tg_config"

# =============================
# 获取 Telegram 参数
# =============================
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "请输入 Telegram Bot Token:"
    read -r TG_BOT_TOKEN
    echo "请输入 Telegram Chat ID:"
    read -r TG_CHAT_ID
    # 保存到配置文件
    echo "TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"" > "$CONFIG_FILE"
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "配置已保存到 $CONFIG_FILE"
fi

# =============================
# 临时输出文件
# =============================
OUTPUT_FILE="/tmp/vps_network_info.txt"

# =============================
# 系统信息
# =============================
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

# =============================
# 网络接口信息
# =============================
echo "=== 网络接口信息 ===" >> "$OUTPUT_FILE"

for IFACE in $(ls /sys/class/net/); do
    # 接口类型说明
    DESC="$IFACE"
    [ "$IFACE" = "lo" ] && DESC="$IFACE (回环接口)"
    [ "$IFACE" != "lo" ] && DESC="$IFACE (主网卡)"
    echo "------------------------" >> "$OUTPUT_FILE"
    echo "接口: $DESC" >> "$OUTPUT_FILE"

    # IPv4
    IPV4=$(ip -4 addr show $IFACE | grep -oP 'inet \K[\d./]+')
    [ -n "$IPV4" ] && echo "IPv4: $IPV4" >> "$OUTPUT_FILE" || echo "IPv4: 无" >> "$OUTPUT_FILE"

    # IPv6 全局
    IPV6=$(ip -6 addr show $IFACE scope global | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+')
    [ -n "$IPV6" ] && echo "IPv6: $IPV6" >> "$OUTPUT_FILE" || echo "IPv6: 无" >> "$OUTPUT_FILE"

    # IPv6 链路本地
    LL6=$(ip -6 addr show $IFACE scope link | grep -oP 'inet6 \K[0-9a-f:]+/[0-9]+')
    [ -n "$LL6" ] && echo "链路本地 IPv6: $LL6" >> "$OUTPUT_FILE"

    # MAC
    MAC=$(cat /sys/class/net/$IFACE/address)
    echo "MAC: $MAC" >> "$OUTPUT_FILE"
done
echo "------------------------" >> "$OUTPUT_FILE"

# =============================
# 默认路由
# =============================
echo "" >> "$OUTPUT_FILE"
echo "=== 默认路由 ===" >> "$OUTPUT_FILE"
echo "IPv4 默认路由:" >> "$OUTPUT_FILE"
ip route show default >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "IPv6 默认路由:" >> "$OUTPUT_FILE"
ip -6 route show default >> "$OUTPUT_FILE"

# =============================
# 网络连通性测试
# =============================
echo "" >> "$OUTPUT_FILE"
echo "=== 网络连通性测试 ===" >> "$OUTPUT_FILE"
ping -c 3 8.8.8.8 >> "$OUTPUT_FILE" 2>&1
ping6 -c 3 google.com >> "$OUTPUT_FILE" 2>&1

# 检查 IPv6 网关可达性
GATEWAY6=$(ip -6 route | grep default | awk '{print $3}')
if [ -n "$GATEWAY6" ]; then
    ping6 -c 2 $GATEWAY6 >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "IPv6 网关 $GATEWAY6 可达" >> "$OUTPUT_FILE"
    else
        echo "⚠️ IPv6 网关 $GATEWAY6 不可达" >> "$OUTPUT_FILE"
    fi
fi

# =============================
# 发送 Telegram（美观版）
# =============================
# 处理每个接口分块显示，使用 Markdown 格式
TG_MSG="📡 VPS 网络信息\n\`\`\`$(cat $OUTPUT_FILE)\`\`\`"

curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$TG_MSG"

echo "信息已保存到 $OUTPUT_FILE 并发送到 Telegram"

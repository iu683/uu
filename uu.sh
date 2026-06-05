#!/bin/bash

# =================================================================
# 名称: 流量统计 & VPS/Docker 状态 TG日报管理工具
# =================================================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
GRAY="\033[90m"
NC="\033[0m" # 清除颜色


CONFIG_FILE="/etc/vnstat_tg.conf"  # 配置文件路径
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"  # 报告脚本路径

# --- 1. 环境准备 ---
prepare_env() {
    echo "🔍 正在检查系统环境..."

    # 基础依赖包
    local deps=("vnstat" "bc" "curl" "cron" "sed" "awk")

    # 判断操作系统类型
    if [ -f /etc/debian_version ]; then
        PACKAGE_MANAGER="apt-get"
    elif [ -f /etc/redhat-release ]; then
        PACKAGE_MANAGER="yum"
    else
        echo "❌ 未知操作系统，请手动安装依赖。"
        exit 1
    fi

    # 更新源并安装基础依赖
    if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
        sudo apt-get update -y
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "📥 安装依赖: $dep"
            if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
                sudo apt-get install -y "$dep"
            elif [ "$PACKAGE_MANAGER" == "yum" ]; then
                sudo yum install -y "$dep"
            fi
        fi
    done

    # 特殊处理 cron 服务的包名
    if ! command -v cron &>/dev/null && ! command -v crond &>/dev/null; then
        echo "📥 安装 Cron 服务..."
        if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
            sudo apt-get install -y cron
            sudo systemctl enable cron --now
        elif [ "$PACKAGE_MANAGER" == "yum" ]; then
            sudo yum install -y cronie
            sudo systemctl enable cronie --now
        fi
    fi

    # 安装和启动 vnstat 服务
    if ! systemctl is-active --quiet vnstat; then
        sudo systemctl enable vnstat --now
    fi
    sudo vnstat -u >/dev/null 2>&1  # 初始化 vnstat 数据库
    echo "✅ 环境就绪。"
}

# --- 2. 核心报表逻辑生成 ---
generate_report_logic() {
    local BC_P=$(which bc)
    local VN_P=$(which vnstat)
    local CL_P=$(which curl)

    # 动态写入 logic 脚本
    cat <<'EOF' > $BIN_PATH
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ -f "/etc/vnstat_tg.conf" ] && source "/etc/vnstat_tg.conf" || exit 1

# 修复数字前面的零
fix_zero() {
    [[ $1 == .* ]] && echo "0$1" || echo "$1"
}

# 将流量值转化为 MB
val_to_mb() {
    local raw=$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num=$(echo "$raw" | grep -oE '[0-9.]+' | head -n1)
    [ -z "$num" ] && num=0
    case "$raw" in
        *T*) echo "scale=2; $num * 1048576" | $BC ;;
        *G*) echo "scale=2; $num * 1024" | $BC ;;
        *K*) echo "scale=2; $num / 1024" | $BC ;;
        *)   echo "$num" ;;
    esac
}

# 提取流量数据中的接收和发送流量
get_traffic() {
    echo "$1" | cut -c13- | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' | sed -n "${2}p" | xargs
}

# 生成流量使用进度条
gen_bar() {
    local p=$1; local b=""; [ "$p" -gt 100 ] && p=100
    local c="🟩"; [ "$p" -ge 50 ] && c="🟧"; [ "$p" -ge 80 ] && c="🟥"
    for ((i=0; i<p/10; i++)); do b+="$c"; done
    for ((i=p/10; i<10; i++)); do b+="⬜"; done
    echo "$b"
}

# 1. 流量数据统计
$VN -i $INTERFACE --update >/dev/null 2>&1

# 获取公网 IP
SERVER_IP=$(curl -s --connect-timeout 5 https://ipinfo.io/ip || curl -s --connect-timeout 5 https://icanhazip.com || echo "获取失败")

Y_D=$(date -d "yesterday" "+%Y-%m-%d")
Y_A1=$(date -d "yesterday" "+%m/%d/%y")
Y_A2=$(date -d "yesterday" "+%d.%m.%y")
Y_A3=$(date -d "yesterday" "+%m/%d/%Y")
RAW_LINE=$($VN -d | grep -Ei "yesterday|$Y_D|$Y_A1|$Y_A2|$Y_A3")

if [ -n "$RAW_LINE" ]; then
    RX_STR=$(get_traffic "$RAW_LINE" 1)
    TX_STR=$(get_traffic "$RAW_LINE" 2)
    RX_MB=$(val_to_mb "$RX_STR")
    TX_MB=$(val_to_mb "$TX_STR")
    TOTAL_YEST_GB=$(fix_zero $(echo "scale=2; ($RX_MB + $TX_MB) / 1024" | $BC))
    DISP_RX="${RX_STR/GiB/GB}"; DISP_TX="${TX_STR/GiB/GB}"
else
    DISP_RX="0.00 GB"; DISP_TX="0.00 GB"; TOTAL_YEST_GB="0.00"
fi

TODAY_D=$(date +%d | sed 's/^0//')
THIS_Y=$(date +%Y); THIS_M=$(date +%m)
if [ "$TODAY_D" -lt "$RESET_DAY" ]; then
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 month" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} -1 day" +%Y-%m-%d)
else
    START_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY}" +%Y-%m-%d)
    END_DATE=$(date -d "${THIS_Y}-${THIS_M}-${RESET_DAY} +1 month -1 day" +%Y-%m-%d)
fi

TOTAL_PERIOD_MB=0
CUR_TS=$(date -d "$START_DATE" +%s)
YEST_TS=$(date -d "yesterday" +%s)
while [ "$CUR_TS" -le "$YEST_TS" ]; do
    D_M1=$(date -d "@$CUR_TS" "+%Y-%m-%d")
    D_M2=$(date -d "@$CUR_TS" "+%m/%d/%y")
    D_M3=$(date -d "@$CUR_TS" "+%d.%m.%y")
    D_M4=$(date -d "@$CUR_TS" "+%m/%d/%Y")
    D_LINE=$($VN -d | grep -E "$D_M1|$D_M2|$D_M3|$D_M4")
    if [ -n "$D_LINE" ]; then
        D_RX_S=$(get_traffic "$D_LINE" 1)
        D_TX_S=$(get_traffic "$D_LINE" 2)
        TOTAL_PERIOD_MB=$(echo "$TOTAL_PERIOD_MB + $(val_to_mb "$D_RX_S") + $(val_to_mb "$D_TX_S")" | $BC)
    fi
    CUR_TS=$((CUR_TS + 86400))
done

USED_GB=$(fix_zero $(echo "scale=2; $TOTAL_PERIOD_MB / 1024" | $BC))
PCT=$(echo "scale=0; $USED_GB * 100 / $MAX_GB" | $BC 2>/dev/null)
[ -z "$PCT" ] && PCT=0
BAR=$(gen_bar $PCT)
NOW=$(date "+%Y-%m-%d %H:%M")

# 2. VPS 基础状态获取 & 运行时间汉化
UPTIME_RAW=$(uptime -p | sed 's/up //')
UPTIME_CN=$(echo "$UPTIME_RAW" | sed -E 's/ years?/ 年/g; s/ weeks?/ 周/g; s/ days?/ 天/g; s/ hours?/ 小时/g; s/ minutes?/ 分钟/g')

CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | xargs)
MEM_INFO=$(free -m | awk '/Mem:/ {printf "%.1f/%.1f GB (%.0f%%)", $3/1024, $2/1024, $3*100/$2}')
DISK_INFO=$(df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')

# 3. 网卡实时速率统计 (1秒采样)
RX_BEFORE=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
TX_BEFORE=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
sleep 1
RX_AFTER=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
TX_AFTER=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
SPEED_RX_KB=$(echo "($RX_AFTER - $RX_BEFORE) / 1024" | $BC)
SPEED_TX_KB=$(echo "($TX_AFTER - $TX_BEFORE) / 1024" | $BC)

if [ "$SPEED_RX_KB" -gt 1024 ]; then
    SPEED_RX=$(echo "scale=1; $SPEED_RX_KB / 1024" | $BC) Mbps
else
    SPEED_RX="${SPEED_RX_KB} Kbps"
fi
if [ "$SPEED_TX_KB" -gt 1024 ]; then
    SPEED_TX=$(echo "scale=1; $SPEED_TX_KB / 1024" | $BC) Mbps
else
    SPEED_TX="${SPEED_TX_KB} Kbps"
fi

# 4. Docker 运行状态监控（优化：未安装或未运行则完全隐藏该板块）
DOCKER_BLOCK=""
if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
    DOCKER_TOTAL=$(docker ps -a --format '{{.Names}}' | wc -l)
    DOCKER_RUNNING=$(docker ps --format '{{.Names}}' | wc -l)
    DOCKER_STATUS="🟢 运行中 ($DOCKER_RUNNING/$DOCKER_TOTAL)"
    
    # 异常容器检测
    DOCKER_EXC=$(docker ps -a --filter "status=exited" --format '{{.Names}} ({{.Status}})' | grep -v 'Exited (0)' | head -n 3)
    if [ -n "$DOCKER_EXC" ]; then
        DOCKER_STATUS+="\n⚠️ *异常容器*:\n\`$(echo "$DOCKER_EXC" | sed 's/^/  • /')\`"
    fi
    
    # 构建 Docker 消息文本块
    read -r -d '' DOCKER_BLOCK << DOCK_MSG

🐳 *Docker 运行状态*
$DOCKER_STATUS
DOCK_MSG
fi

# --- 报表样式定制（分开显示周期） ---
read -r -d '' MSG << END_OF_MESSAGE
📊 *【$HOST_ALIAS】服务器日报*
🕙 时间: \`$NOW\`
🔋 运行: \`$UPTIME_CN\`

🖥️ *VPS 基础性能监控*
├─ 🌍 公网IP: \`$SERVER_IP\`
├─ ⚡ 负载 (1m): \`$CPU_LOAD\`
├─ 🧠 内存: \`$MEM_INFO\`
└─ 💾 硬盘: \`$DISK_INFO\`

🌐 *网卡实时与历史统计 ($INTERFACE)*
├─ 🚀 实时下载: \`$SPEED_RX\`
├─ 🚀 实时上传: \`$SPEED_TX\`
├─ ⬇️ 昨日下载: \`$DISP_RX\`
├─ ⬆️ 昨日上传: \`$DISP_TX\`
└─ 🧮 昨日合计: \`$TOTAL_YEST_GB GB\`

📅 *流量周期统计*
├─ 📅 周期开始: \`$START_DATE\`
├─ 📅 周期结束: \`$END_DATE\`
├─ 🔄 重置日: 每月 \`$RESET_DAY\` 号
├─ ⏳ 累计: \`$USED_GB / $MAX_GB GB\`
└─ 🎯 进度: $BAR \`$PCT%\`$DOCKER_BLOCK
END_OF_MESSAGE

# 发送到 Telegram
$CL --connect-timeout 10 --retry 3 -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
-d "chat_id=$TG_CHAT_ID" \
-d "text=$MSG" \
-d "parse_mode=Markdown" \
-d "disable_notification=true" > /dev/null
EOF

    # 更新报告脚本中的命令路径
    sed -i "4i BC=\"$BC_P\"\nVN=\"$VN_P\"\nCL=\"$CL_P\"" $BIN_PATH
    chmod +x $BIN_PATH  # 设置执行权限
}

# --- 3. 配置与自定义通知时间录入 ---
collect_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    echo "--- 请输入配置参数 ---"
    
    read -p "👤 主机别名 [${HOST_ALIAS:-My-VPS}]: " input_val; HOST_ALIAS=${input_val:-${HOST_ALIAS:-My-VPS}}
    read -p "🤖 Bot Token [${TG_TOKEN}]: " input_val; TG_TOKEN=${input_val:-$TG_TOKEN}
    read -p "🆔 Chat ID [${TG_CHAT_ID}]: " input_val; TG_CHAT_ID=${input_val:-$TG_CHAT_ID}
    read -p "📅 重置日 (1-31) [${RESET_DAY:-1}]: " input_val; RESET_DAY=${input_val:-${RESET_DAY:-1}}
    read -p "📊 限额 (GB) [${MAX_GB:-1000}]: " input_val; MAX_GB=${input_val:-${MAX_GB:-1000}}

    # 自动获取默认网卡
    IF_DEF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    read -p "🌐 网卡 [${INTERFACE:-$IF_DEF}]: " input_val; INTERFACE=${input_val:-${INTERFACE:-$IF_DEF}}

    # 自定义通知时间
    read -p "⏰ 通知时间 (HH:MM) [${RUN_TIME:-08:00}]: " input_val; RUN_TIME=${input_val:-${RUN_TIME:-08:00}}

    # 保存配置到文件
    cat <<EOF > "$CONFIG_FILE"
HOST_ALIAS="$HOST_ALIAS"
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
RESET_DAY=$RESET_DAY
MAX_GB=$MAX_GB
INTERFACE="$INTERFACE"
RUN_TIME="$RUN_TIME"
EOF

    # 生成报告脚本
    generate_report_logic  
    
    # 巧妙转换 Cron 时间，过滤掉前导0
    local H=$(echo $RUN_TIME | cut -d: -f1 | sed 's/^0//'); [ -z "$H" ] && H=0
    local M=$(echo $RUN_TIME | cut -d: -f2 | sed 's/^0//'); [ -z "$M" ] && M=0
    
    # 写入定时任务
    (crontab -l 2>/dev/null | grep -Fv "$BIN_PATH"; echo "$M $H * * * /bin/bash $BIN_PATH") | crontab -
    echo "⏰ 定时发送任务已设定为每日 $RUN_TIME"
}

# --- 4. 交互菜单 (带有状态与定时任务检测功能) ---

while true; do
    clear
    echo -e "${GREEN}=======================================${NC}"
    echo -e "${GREEN}       流量日报 TG通知管理工具         ${NC}"
    echo -e "${GREEN}=======================================${NC}"
    
    # --- 动态状态看板模块 ---
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN} 👤 主机别名:${NC} ${YELLOW}$HOST_ALIAS${NC} | 网卡: ${YELLOW}$INTERFACE${NC}"
        echo -e "${GREEN} 📅 流量配置:${NC} 每月 ${YELLOW}$RESET_DAY${NC} 号重置 | 限额: ${YELLOW}$MAX_GB GB${NC}"
        
        # 检查 crontab 中是否有该定时任务
        if crontab -l 2>/dev/null | grep -Fq "$BIN_PATH"; then
            echo -e "${GREEN}  ⏰ 定时任务:${NC} ${YELLOW}已开启 (每日 $RUN_TIME)${NC}"
        else
            echo -e "${GREEN}  ⏰ 定时任务:${NC} ${RED}未开启 (无定时任务)${NC}"
        fi
    else
        echo -e "${GREEN} 📊 当前状态:${NC} ${YELLOW}未检测到有效配置文件，请先执行安装${NC}"
    fi
    echo -e "${GREEN}=======================================${NC}"

    # --- 菜单选项 ---
    echo -e "${GREEN} 1. 全新安装环境与配置${NC}"
    echo -e "${GREEN} 2. 修改现有配置/调整通知时间${NC}"
    echo -e "${GREEN} 3. 立即手动触发测试 (发送日报)${NC}"
    echo -e "${GREEN} 4. 重新构建报表核心逻辑 (更新)${NC}"
    echo -e "${GREEN} 5. 完全卸载 (清理配置与定时任务)${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}=======================================${NC}"

    echo -ne "${GREEN} 请选择操作: ${NC}"
    read choice
    case $choice in
        1) 
            prepare_env
            collect_config
            echo -e "\n✅ 安装完成！"; sleep 2 
            ;;
        2) 
            collect_config
            echo -e "\n✅ 配置与通知时间更新成功！"; sleep 2 
            ;;
        3) 
            echo "📡 正在尝试发送日报，请稍候..."
            if [ -f "$BIN_PATH" ]; then
                if /bin/bash "$BIN_PATH"; then
                    echo -e "✅ ${GREEN}日报已成功触发并向 Telegram 发送！${NC}"
                else
                    echo -e "❌ ${RED}发送失败，请检查您的 Token/ChatID 设定、网络状况或 API 连通性。${NC}"
                fi
            else
                echo -e "❌ ${RED}错误：核心报告脚本尚未生成，请先执行选项 1 安装。${NC}"
            fi
            sleep 3 
            ;;
        4) 
            if [ -f "$CONFIG_FILE" ]; then
                generate_report_logic
                echo -e "✅ ${GREEN}核心逻辑已更新重构！${NC}"
            else
                echo -e "❌ ${RED}更新失败：配置文件未找到，请先安装。${NC}"
            fi
            sleep 1.5 
            ;;
        5) 
            echo "🔄 正在卸载工具并清理残留..."
            (crontab -l 2>/dev/null | grep -v "$BIN_PATH") | crontab -
            rm -f "$BIN_PATH" "$CONFIG_FILE"
            echo -e "✅ ${GREEN}卸载成功！已彻底清理配置文件以及 Cron 定时任务。${NC}"
            sleep 2 
            ;;
        0) 
            exit 0 
            ;;
        *) 
            echo -e "❌ ${RED}无效选项，请输入 0 到 5 之间的数字${NC}"
            sleep 1 
            ;;
    esac
done

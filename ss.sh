#!/bin/sh

# =================================================================
# 名称: 流量统计 & VPS/Docker 状态 TG日报管理工具 (Alpine 专属版)
# =================================================================

GREEN="\033[32m"
NC="\033[0m" # 清除颜色

CONFIG_FILE="/etc/vnstat_tg.conf"  # 配置文件路径
BIN_PATH="/usr/local/bin/vnstat_tg_report.sh"  # 报告脚本路径

# --- 1. 环境准备 ---
prepare_env() {
    echo "🔍 正在检查 Alpine 系统环境..."

    # 1. 检查并安装 apk 基础依赖 (去掉了会冲突的 cronie)
    local deps="vnstat bc curl sed awk coreutils procps"
    
    echo "📥 更新 apk 软件源并安装依赖..."
    apk update
    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "📥 安装依赖: $dep"
            apk add "$dep"
        fi
    done

    # 2. OpenRC 服务管理 (Alpine 专属优化)
    # Alpine 默认自带 dcron (服务名为 crond)，直接检查并启动即可
    if ! rc-service crond status >/dev/null 2>&1; then
        echo "📥 启动 Cron 服务..."
        rc-update add crond default >/dev/null 2>&1
        rc-service crond start
    fi

    # 探测 vnstat 在 Alpine 里的真实服务名 (可能是 vnstat 或 vnstatd)
    local vnstat_service="vnstat"
    if [ ! -f "/etc/init.d/vnstat" ] && [ -f "/etc/init.d/vnstatd" ]; then
        vnstat_service="vnstatd"
    fi

    # 启动并开机自启 vnstat 服务
    if [ -f "/etc/init.d/$vnstat_service" ]; then
        if ! rc-service "$vnstat_service" status >/dev/null 2>&1; then
            echo "📥 启动 $vnstat_service 服务..."
            rc-update add "$vnstat_service" default >/dev/null 2>&1
            rc-service "$vnstat_service" start
        fi
    else
        echo "⚠️ 未找到 vnstat 的系统服务脚本，尝试后台直接启动守护进程..."
        if ! pgrep vnstatd >/dev/null 2>&1; then
            vnstatd -d
        fi
    fi
    
    # 初始化 vnstat 数据库
    vnstat -u >/dev/null 2>&1  
    echo "✅ 环境就绪。"
}
# --- 2. 核心报表逻辑生成 ---
generate_report_logic() {
    local BC_P=$(which bc)
    local VN_P=$(which vnstat)
    local CL_P=$(which curl)
    local DATE_P=$(which date) # 确保使用的是 GNU date

    # 动态写入逻辑脚本
    cat <<EOF > $BIN_PATH
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ -f "/etc/vnstat_tg.conf" ] && . "/etc/vnstat_tg.conf" || exit 1

BC="$BC_P"
VN="$VN_P"
CL="$CL_P"
GDATE="$DATE_P"

# 修复数字前面的零
fix_zero() {
    case "\$1" in
        .*) echo "0\$1" ;;
        *)  echo "\$1" ;;
    esac
}

# 将流量值转化为 MB
val_to_mb() {
    local raw=\$(echo "\$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num=\$(echo "\$raw" | grep -oE '[0-9.]+' | head -n1)
    [ -z "\$num" ] && num=0
    case "\$raw" in
        *T*) echo "scale=2; \$num * 1048576" | \$BC ;;
        *G*) echo "scale=2; \$num * 1024" | \$BC ;;
        *K*) echo "scale=2; \$num / 1024" | \$BC ;;
        *)   echo "\$num" ;;
    esac
}

# 提取流量数据中的接收和发送流量
get_traffic() {
    echo "\$1" | cut -c13- | grep -oE '[0-9.]+[[:space:]]*[a-zA-Z/]+' | sed -n "\${2}p" | xargs
}

# 生成流量使用进度条
gen_bar() {
    local p=\$1; local b=""; [ "\$p" -gt 100 ] && p=100
    local c="🟩"; [ "\$p" -ge 50 ] && c="🟧"; [ "\$p" -ge 80 ] && c="🟥"
    
    # 用 while 循环替代 bash 的 for (i=0; i<p/10; i++)
    local i=0
    local limit=\$((p / 10))
    while [ \$i -lt \$limit ]; do
        b="\$b\$c"
        i=\$((i + 1))
    done
    while [ \$i -lt 10 ]; do
        b="\$b⬜"
        i=\$((i + 1))
    done
    echo "\$b"
}

# 1. 流量数据统计
\$VN -i \$INTERFACE --update >/dev/null 2>&1

# 获取公网 IP
SERVER_IP=\$(\$CL -s --connect-timeout 5 https://ipinfo.io/ip || \$CL -s --connect-timeout 5 https://icanhazip.com || echo "获取失败")

Y_D=\$(\$GDATE -d "yesterday" "+%Y-%m-%d")
Y_A1=\$(\$GDATE -d "yesterday" "+%m/%d/%y")
Y_A2=\$(\$GDATE -d "yesterday" "+%d.%m.%y")
Y_A3=\$(\$GDATE -d "yesterday" "+%m/%d/%Y")
RAW_LINE=\$(\$VN -d | grep -Ei "yesterday|\$Y_D|\$Y_A1|\$Y_A2|\$Y_A3")

if [ -n "\$RAW_LINE" ]; then
    RX_STR=\$(get_traffic "\$RAW_LINE" 1)
    TX_STR=\$(get_traffic "\$RAW_LINE" 2)
    RX_MB=\$(val_to_mb "\$RX_STR")
    TX_MB=\$(val_to_mb "\$TX_STR")
    TOTAL_YEST_GB=\$(fix_zero \$(echo "scale=2; (\$RX_MB + \$TX_MB) / 1024" | \$BC))
    DISP_RX=\$(echo "\$RX_STR" | sed 's/GiB/GB/'); DISP_TX=\$(echo "\$TX_STR" | sed 's/GiB/GB/')
else
    DISP_RX="0.00 GB"; DISP_TX="0.00 GB"; TOTAL_YEST_GB="0.00"
fi

TODAY_D=\$(\$GDATE +%d | sed 's/^0//')
THIS_Y=\$(\$GDATE +%Y); THIS_M=\$(\$GDATE +%m)
if [ "\$TODAY_D" -lt "\$RESET_DAY" ]; then
    START_DATE=\$(\$GDATE -d "\${THIS_Y}-\${THIS_M}-\${RESET_DAY} -1 month" +%Y-%m-%d)
    END_DATE=\$(\$GDATE -d "\${THIS_Y}-\${THIS_M}-\${RESET_DAY} -1 day" +%Y-%m-%d)
else
    START_DATE=\$(\$GDATE -d "\${THIS_Y}-\${THIS_M}-\${RESET_DAY}" +%Y-%m-%d)
    END_DATE=\$(\$GDATE -d "\${THIS_Y}-\${THIS_M}-\${RESET_DAY} +1 month -1 day" +%Y-%m-%d)
fi

TOTAL_PERIOD_MB=0
CUR_TS=\$(\$GDATE -d "\$START_DATE" +%s)
YEST_TS=\$(\$GDATE -d "yesterday" +%s)
while [ "\$CUR_TS" -le "\$YEST_TS" ]; do
    D_M1=\$(\$GDATE -d "@\$CUR_TS" "+%Y-%m-%d")
    D_M2=\$(\$GDATE -d "@\$CUR_TS" "+%m/%d/%y")
    D_M3=\$(\$GDATE -d "@\$CUR_TS" "+%d.%m.%y")
    D_M4=\$(\$GDATE -d "@\$CUR_TS" "+%m/%d/%Y")
    D_LINE=\$(\$VN -d | grep -E "\$D_M1|\$D_M2|\$D_M3|\$D_M4")
    if [ -n "\$D_LINE" ]; then
        D_RX_S=\$(get_traffic "\$D_LINE" 1)
        D_TX_S=\$(get_traffic "\$D_LINE" 2)
        TOTAL_PERIOD_MB=\$(echo "\$TOTAL_PERIOD_MB + \$(val_to_mb "\$D_RX_S") + \$(val_to_mb "\$D_TX_S")" | \$BC)
    fi
    CUR_TS=\$((\$CUR_TS + 86400))
done

USED_GB=\$(fix_zero \$(echo "scale=2; \$TOTAL_PERIOD_MB / 1024" | \$BC))
PCT=\$(echo "scale=0; \$USED_GB * 100 / \$MAX_GB" | \$BC 2>/dev/null)
[ -z "\$PCT" ] && PCT=0
BAR=\$(gen_bar \$PCT)
NOW=\$(\$GDATE "+%Y-%m-%d %H:%M")

# 2. VPS 基础状态获取 & 运行时间汉化
UPTIME_RAW=\$(uptime | awk -F'up ' '{print \$2}' | awk -F, '{print \$1}' | xargs)
UPTIME_CN=\$(echo "\$UPTIME_RAW" | sed -E 's/ years?/ 年/g; s/ weeks?/ 周/g; s/ days?/ 天/g; s/ hours?/ 小时/g; s/ minutes?/ 分钟/g')

CPU_LOAD=\$(uptime | awk -F'load average:' '{print \$2}' | awk -F, '{print \$1}' | xargs)
MEM_INFO=\$(free -m | awk '/Mem:/ {printf "%.1f/%.1f GB (%.0f%%)", \$3/1024, \$2/1024, \$3*100/\$2}')
DISK_INFO=\$(df -h / | awk 'NR==2 {printf "%s/%s (%s)", \$3, \$2, \$5}')

# 3. 网卡实时速率统计 (1秒采样)
RX_BEFORE=\$(cat /sys/class/net/\$INTERFACE/statistics/rx_bytes)
TX_BEFORE=\$(cat /sys/class/net/\$INTERFACE/statistics/tx_bytes)
sleep 1
RX_AFTER=\$(cat /sys/class/net/\$INTERFACE/statistics/rx_bytes)
TX_AFTER=\$(cat /sys/class/net/\$INTERFACE/statistics/tx_bytes)
SPEED_RX_KB=\$(echo "(\$RX_AFTER - \$RX_BEFORE) / 1024" | \$BC)
SPEED_TX_KB=\$(echo "(\$TX_AFTER - \$TX_BEFORE) / 1024" | \$BC)

if [ "\$SPEED_RX_KB" -gt 1024 ]; then
    SPEED_RX="\$(echo "scale=1; \$SPEED_RX_KB / 1024" | \$BC) Mbps"
else
    SPEED_RX="\${SPEED_RX_KB} Kbps"
fi
if [ "$SPEED_TX_KB" -gt 1024 ]; then
    SPEED_TX="\$(echo "scale=1; \$SPEED_TX_KB / 1024" | \$BC) Mbps"
else
    SPEED_TX="\${SPEED_TX_KB} Kbps"
fi

# 4. Docker 运行状态监控 (Alpine 兼容)
DOCKER_BLOCK=""
if command -v docker >/dev/null 2>&1 && rc-service docker status >/dev/null 2>&1; then
    DOCKER_TOTAL=\$(docker ps -a --format '{{.Names}}' | wc -l)
    DOCKER_RUNNING=\$(docker ps --format '{{.Names}}' | wc -l)
    DOCKER_STATUS="🟢 运行中 (\$DOCKER_RUNNING/\$DOCKER_TOTAL)"
    
    DOCKER_EXC=\$(docker ps -a --filter "status=exited" --format '{{.Names}} ({{.Status}})' | grep -v 'Exited (0)' | head -n 3)
    if [ -n "\$DOCKER_EXC" ]; then
        DOCKER_STATUS="\$DOCKER_STATUS\n⚠️ *异常容器*:\n\\\`\$(echo "\$DOCKER_EXC" | sed 's/^/  • /')\\\`"
    fi
    
    DOCKER_BLOCK="
🐳 *Docker 运行状态*
\$DOCKER_STATUS"
fi

# --- 报表样式定制 ---
MSG="📊 *【\$HOST_ALIAS】服务器日报*
🕙 时间: \\\`\$NOW\\\`
🔋 运行: \\\`\$UPTIME_CN\\\`

🖥️ *VPS 基础性能监控*
├─ 🌍 公网IP: \\\`\$SERVER_IP\\\`
├─ ⚡ 负载 (1m): \\\`\$CPU_LOAD\\\`
├─ 🧠 内存: \\\`\$MEM_INFO\\\`
└─ 💾 硬盘: \\\`\$DISK_INFO\\\`

🌐 *网卡实时与历史统计 (\$INTERFACE)*
├─ 🚀 实时下载: \\\`\$SPEED_RX\\\`
├─ 🚀 实时上传: \\\`\$SPEED_TX\\\`
├─ ⬇️ 昨日下载: \\\`\$DISP_RX\\\`
├─ ⬆️ 昨日上传: \\\`\$DISP_TX\\\`
└─ 🧮 昨日合计: \\\`\$TOTAL_YEST_GB GB\\\`

📅 *流量周期统计*
├─ 📅 周期开始: \\\`\$START_DATE\\\`
├─ 📅 周期结束: \\\`\$END_DATE\\\`
├─ 🔄 重置日: 每月 \\\`\$RESET_DAY\\\` 号
├─ ⏳ 累计: \\\`\$USED_GB / \$MAX_GB GB\\\`
└─ 🎯 进度: \$BAR \\\`\$PCT%\\\`\$DOCKER_BLOCK"

# 发送到 Telegram
\$CL --connect-timeout 10 --retry 3 -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" \\
-d "chat_id=\$TG_CHAT_ID" \\
-d "text=\$MSG" \\
-d "parse_mode=Markdown" \\
-d "disable_notification=true" > /dev/null
EOF

    chmod +x $BIN_PATH  # 设置执行权限
}

# --- 3. 配置与自定义通知时间录入 ---
collect_config() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
    echo "--- 请输入配置参数 ---"
    
    printf "👤 主机别名 [%s]: " "${HOST_ALIAS:-My-VPS}"; read input_val; HOST_ALIAS=${input_val:-${HOST_ALIAS:-My-VPS}}
    printf "🤖 Bot Token [%s]: " "${TG_TOKEN}"; read input_val; TG_TOKEN=${input_val:-$TG_TOKEN}
    printf "🆔 Chat ID [%s]: " "${TG_CHAT_ID}"; read input_val; TG_CHAT_ID=${input_val:-$TG_CHAT_ID}
    printf "📅 重置日 (1-31) [%s]: " "${RESET_DAY:-1}"; read input_val; RESET_DAY=${input_val:-${RESET_DAY:-1}}
    printf "📊 限额 (GB) [%s]: " "${MAX_GB:-1000}"; read input_val; MAX_GB=${input_val:-${MAX_GB:-1000}}

    # 自动获取默认网卡
    IF_DEF=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
    printf "🌐 网卡 [%s]: " "${INTERFACE:-$IF_DEF}"; read input_val; INTERFACE=${input_val:-${INTERFACE:-$IF_DEF}}

    # 自定义通知时间
    printf "⏰ 通知时间 (HH:MM) [%s]: " "${RUN_TIME:-08:00}"; read input_val; RUN_TIME=${input_val:-${RUN_TIME:-08:00}}

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
    
    # Alpine crontab 兼容写入
    (crontab -l 2>/dev/null | grep -v "$BIN_PATH"; echo "$M $H * * * /bin/sh $BIN_PATH") | crontab -
    echo "⏰ 定时发送任务已设定为每日 $RUN_TIME"
}

# --- 4. 交互菜单 (绿色矩阵风) ---
while true; do
    clear
    echo -e "${GREEN}==========================${NC}"
    echo -e "${GREEN}     流量日报 TG通知工具   ${NC}"
    echo -e "${GREEN}==========================${NC}"
    echo -e "${GREEN} 1. 安装${NC}"
    echo -e "${GREEN} 2. 修改配置${NC}"
    echo -e "${GREEN} 3. 发送测试${NC}"
    echo -e "${GREEN} 4. 更新${NC}"
    echo -e "${GREEN} 5. 卸载${NC}"
    echo -e "${GREEN} 0. 退出${NC}"
    echo -e "${GREEN}==========================${NC}"

    printf "${GREEN} 请选择: ${NC}"
    read choice
    case $choice in
        1) prepare_env; collect_config; echo "✅ 安装完成！"; sleep 2 ;;
        2) collect_config; echo "✅ 配置与通知时间更新成功！"; sleep 2 ;;
        3) 
            if [ -f "$BIN_PATH" ]; then
                /bin/sh "$BIN_PATH" && echo "✅ 日报已触发发送！" || echo "❌ 发送失败，请检查配置或网络。"; 
            else
                echo "❌ 报告脚本尚未生成，请先执行全新安装或修改配置。";
            fi
            sleep 3 ;;
        4) generate_report_logic; echo "✅ 已更新！"; sleep 1 ;;
        5) 
            (crontab -l 2>/dev/null | grep -v "$BIN_PATH") | crontab -; 
            rm -f "$BIN_PATH" "$CONFIG_FILE"; 
            echo "✅ 卸载成功，已清理配置文件及 Cron 定时任务。"; 
            sleep 2 ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项"; sleep 1 ;;
    esac
done

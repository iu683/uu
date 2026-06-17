#!/bin/bash
# ========================================
# aria2 系统原生包管理器全能管理与下载工具
# 支持 Systemd (Ubuntu) / OpenRC (Alpine) 双保活
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

CONFIG_DIR="/etc/aria2"
CONFIG_FILE="$CONFIG_DIR/aria2.conf"
DOWNLOAD_DIR="/opt/aria2_downloads"

mkdir -p "$CONFIG_DIR"
mkdir -p "$DOWNLOAD_DIR"

PROMPT_CHOICE=$(echo -e "${GREEN}请输入选项: ${RESET}")
PROMPT_CONTINUE=$(echo -e "${GREEN}按回车继续...${RESET}")

get_aria_status() {
    if command -v systemctl &>/dev/null && systemctl is-active aria2 &>/dev/null; then
        echo -e "${GREEN}运行 (Systemd 守护中)${RESET}"
    elif command -v rc-service &>/dev/null && rc-service aria2 status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}运行 (OpenRC 守护中)${RESET}"
    elif pgrep aria2c &>/dev/null; then
        echo -e "${GREEN}运行 (普通后台进程)${RESET}"
    else
        echo -e "${RED}停止 (未运行)${RESET}"
    fi
}

get_aria_version() {
    if command -v aria2c &>/dev/null; then
        aria2c -v | head -n 1 | awk '{print $3}'
    else
        echo "无"
    fi
}

get_current_token() {
    if [ -f "$CONFIG_FILE" ]; then
        grep "^rpc-secret=" "$CONFIG_FILE" | cut -d'=' -f2
    else
        echo "未生成"
    fi
}


get_public_ip() {
    local mode=${1:-"auto"} # auto: 自动, v4: 强制IPv4, v6: 强制IPv6
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        # 强制获取 IPv4
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        # 强制获取 IPv6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        # auto 模式：双栈环境优先获取 IPv4 (更适合大众网络)，纯 v6 环境自动fallback到 v6
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        # 如果获取 v4 失败，说明可能是纯 v6 机器，尝试获取 v6
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi

    # 兜底处理：所有接口都失败时，直接输出 127.0.0.1，不报错
    echo "127.0.0.1" && return 0
}

# 全自动化环境配置 + 双系统级后台驻留机制
install_or_update_aria2() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 权限或 sudo 运行此脚本！${RESET}"
        return
    fi

    echo -e "${GREEN}正在检测系统包管理器环境并拉取主程序...${RESET}"
    
    local is_alpine=false
    if command -v apt &>/dev/null; then
        apt update -y
        apt install aria2 curl grep wget -y
    elif command -v apk &>/dev/null; then
        apk update
        apk add aria2 curl grep bash openrc
        is_alpine=true
    else
        echo -e "${RED}❌ 抱歉，当前系统既不是 APT 也不支持 APK，无法进行自动化安装。${RESET}"
        return
    fi

    if ! command -v aria2c &>/dev/null; then
        echo -e "${RED}❌ 安装失败，请检查您的软件源或网络连接！${RESET}"
        return
    fi

    # 1. 动态生成或继承安全密钥
    local current_token=$(get_current_token)
    if [ "$current_token" = "未生成" ] || [ -z "$current_token" ]; then
        current_token=$(date +%s | sha256sum | base64 | head -c 16)
    fi

    # 2. 覆盖写入全局配置文件
    cat <<EOF > "$CONFIG_FILE"
dir=$DOWNLOAD_DIR
continue=true
max-concurrent-downloads=5
max-connection-per-server=16
min-split-size=10M
split=10
rpc-listen-port=6800
enable-rpc=true
rpc-allow-origin-all=true
rpc-listen-all=true
rpc-secret=$current_token
file-allocation=none
enable-dht=true
enable-peer-exchange=true
bt-max-peers=128
seed-time=0
EOF

    # 3. 核心保活：智能判断初始化守护系统
    if [ "$is_alpine" = true ] && command -v rc-service &>/dev/null; then
        echo -e "${GREEN}检测到 Alpine 环境，正在注入 OpenRC 服务守护和保活脚本...${RESET}"
        rc-service aria2 stop &>/dev/null
        
        # 编写 Alpine 标准的 OpenRC 服务脚本 (带 respawn 自动崩溃重启保活)
        cat <<'EOF' > /etc/init.d/aria2
#!/sbin/openrc-run

description="Aria2 Download Utility"
command="/usr/bin/aria2c"
command_args="--conf-path=/etc/aria2/aria2.conf"
command_background="yes"
pidfile="/run/aria2.pid"

# OpenRC 的核心保活配置：挂掉后自愈重启
respawn_delay=5
respawn_max=10

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/aria2
        # 激活开机自启并立刻拉起
        rc-update add aria2 default &>/dev/null
        rc-service aria2 start
    elif command -v systemctl &>/dev/null; then
        echo -e "${GREEN}检测到 Debian/Ubuntu 环境，正在将 Aria2 挂载为 Systemd 服务...${RESET}"
        systemctl stop aria2 &>/dev/null
        
        cat <<EOF > /etc/systemd/system/aria2.service
[Unit]
Description=Aria2 High Performance Download Utility
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/aria2c --conf-path=$CONFIG_FILE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable aria2 &>/dev/null
        systemctl start aria2
    else
        # 没有任何高级 init 系统的极简容器环境，用传统 nohup 兜底
        pkill aria2c &>/dev/null
        nohup aria2c --conf-path="$CONFIG_FILE" >/dev/null 2>&1 &
    fi

    # 4. 全自动输出 Web 联机配置凭证
    local public_ip=$(get_public_ip)
    local current_version=$(get_aria_version)

    clear
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 🎉 Aria2 核心及原生系统守护服务 部署完成！       ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 软件版本: v$current_version${RESET}"
    echo -e "${GREEN} 运行状态: $(get_aria_status)${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW} 👇 请直接将以下参数填入你的 AriaNg 或 WebUI 界面中: ${RESET}"
    echo -e "${GREEN} 🌐 RPC 地址 (域名/IP) : ${RESET}${YELLOW}http://$public_ip:6800/jsonrpc${RESET}"
    echo -e "${GREEN} 🔌 RPC 端口 (Port)    : ${RESET}${YELLOW}6800${RESET}"
    echo -e "${GREEN} 🔐 RPC 密钥 (Token)   : ${RESET}${RED}$current_token${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

uninstall_aria2() {
    echo -e "${YELLOW}正在清理 aria2 系统服务及程序...${RESET}"
    if command -v rc-service &>/dev/null; then
        rc-service aria2 stop &>/dev/null
        rc-update del aria2 default &>/dev/null
        rm -f /etc/init.d/aria2
    elif command -v systemctl &>/dev/null; then
        systemctl stop aria2 &>/dev/null
        systemctl disable aria2 &>/dev/null
        rm -f /etc/systemd/system/aria2.service
        systemctl daemon-reload
    fi
    pkill aria2c &>/dev/null
    
    if command -v apt &>/dev/null; then
        apt remove aria2 -y && apt autoremove -y
    elif command -v apk &>/dev/null; then
        apk del aria2
    fi
    rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}卸载清理完成。${RESET}"
}

show_rpc_credentials() {
    local public_ip=$(curl -s -m 4 https://api.ipify.org || curl -s -m 4 https://ifconfig.me || echo "你的VPS公网IP")
    local current_token=$(get_current_token)
    
    if [ "$current_token" = "未生成" ]; then
        echo -e "${RED}未发现有效的配置文件，请先执行选项 1 安装/初始化环境！${RESET}"
        return
    fi
    
    clear
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         Aria2 远程 Web 连接配置凭证查询               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 🌐 RPC 地址 (域名/IP) : ${RESET}${YELLOW}http://$public_ip:6800/jsonrpc${RESET}"
    echo -e "${GREEN} 🔌 RPC 端口 (Port)    : ${RESET}${YELLOW}6800${RESET}"
    echo -e "${GREEN} 🔐 RPC 密钥 (Token)   : ${RESET}${RED}$current_token${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}


set_download_dir() {
    read -e -p "$(echo -e "${GREEN}当前保存目录为: ${YELLOW}$DOWNLOAD_DIR${RESET}\n${GREEN}请输入新的保存路径: ${RESET}")" new_dir
    if [ -n "$new_dir" ]; then
        DOWNLOAD_DIR="$new_dir"
        mkdir -p "$DOWNLOAD_DIR"
        echo -e "${GREEN}保存路径已成功修改为: ${YELLOW}$DOWNLOAD_DIR${RESET}"
    else
        echo -e "${YELLOW}输入为空，路径保持不变。${RESET}"
    fi
}

check_aria_ready() {
    if ! command -v aria2c &>/dev/null; then
        echo -e "${RED}错误：请先选择选项 1 安装 aria2 才能使用下载功能！${RESET}"
        return 1
    fi
    return 0
}

# 使用 Cloudflare CDN 官方格式化分流源，实现毫秒级拉取与无缝注入（公网BT专用）
get_dynamic_trackers() {
    echo -e "${GREEN}正在通过 Cloudflare CDN 全速获取精选 Tracker 列表...${RESET}" >&2
    
    local trackers=""
    local cdn_urls=(
        "https://cf.trackerslist.com/best_aria2.txt"
        "https://cf.trackerslist.com/all_aria2.txt"
    )
    
    for url in "${cdn_urls[@]}"; do
        echo -e "${GREEN}正在连接直连加速节点: ${YELLOW}$url${RESET}" >&2
        trackers=$(curl -L -s -k -m 4 "$url" | grep -v '^#' | tr -d '\r' | tr '\n' ',' | sed 's/,,*/,/g' | sed 's/^,//;s/,$//')
        
        if [ -n "$trackers" ] && [[ "$trackers" == *"http"* || "$trackers" == *"udp"* ]]; then
            echo -e "${GREEN}🎉 Tracker 列表秒级同步成功！已成功注入 Aria2 核心引擎。${RESET}" >&2
            echo "$trackers"
            return
        fi
    done

    echo -e "${YELLOW}警告：Cloudflare 专线分流暂时不可用，转入原生多线程 DHT 去中心化寻源模式。${RESET}" >&2
    echo ""
}

# 4. 普通网络链接下载
download_http() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 HTTP/HTTPS/FTP 下载链接: ${RESET}")" url
    [ -z "$url" ] && return
    aria2c -c -s 16 -x 16 -k 1M -d "$DOWNLOAD_DIR" "$url"
}

# 5. 磁力链接下载 (Cloudflare 专线 Tracker + 128多线程加速)
download_magnet() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 Magnet 磁力链接: ${RESET}")" magnet
    [ -z "$magnet" ] && return
    
    local trackers_arg=$(get_dynamic_trackers)
    
    aria2c --seed-time=0 \
           --enable-dht=true \
           --enable-peer-exchange=true \
           --bt-max-peers=128 \
           --max-connection-per-server=16 \
           ${trackers_arg:+--bt-tracker="$trackers_arg"} \
           -d "$DOWNLOAD_DIR" "$magnet"
}

# 6. 种子文件下载 (Cloudflare 专线 Tracker + 128多线程加速)
download_torrent() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 .torrent 种子文件路径或下载链接: ${RESET}")" torrent
    [ -z "$torrent" ] && return
    
    local trackers_arg=$(get_dynamic_trackers)
    
    aria2c --seed-time=0 \
           --enable-dht=true \
           --enable-peer-exchange=true \
           --bt-max-peers=128 \
           --max-connection-per-server=16 \
           ${trackers_arg:+--bt-tracker="$trackers_arg"} \
           -d "$DOWNLOAD_DIR" "$torrent"
}

# 7. PT站专属纯净下载通道 (不注入任何外部Tracker，遵循站点原生规则与私钥)
download_pt_pure() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 PT站专属种子链接 或 .torrent路径: ${RESET}")" pt_target
    [ -z "$pt_target" ] && return
    
    echo -e "${GREEN}正在启动 PT 纯净下载模式（不注入外源 Tracke）...${RESET}"
    
    # PT 下载规范：不允许随便连接 DHT 和 PEX (Peer Exchange)，必须只连接种子内自带的私有 Tracker
    aria2c --seed-time=0 \
           --enable-dht=false \
           --enable-peer-exchange=false \
           -d "$DOWNLOAD_DIR" "$pt_target"
}

# 8. 批量文本链接下载
download_batch_txt() {
    check_aria_ready || return
    echo -e "${GREEN}请连续输入需要下载的链接，每输完一个按一次回车。${RESET}"
    echo -e "${GREEN}输入完毕后，输入英文字母 ${YELLOW}q${GREEN} 即可开始批量下载。${RESET}"
    
    local tmp_txt="/tmp/aria2_urls.txt"
    > "$tmp_txt"
    local count=1
    while true; do
        read -e -p "$(echo -e "${GREEN}输入第 [${YELLOW}$count${GREEN}] 个链接 (输入 q 开始): ${RESET}")" input_url
        if [ "$input_url" = "q" ] || [ "$input_url" = "Q" ]; then break; fi
        if [ -n "$input_url" ]; then
            echo "$input_url" >> "$tmp_txt"
            ((count++))
        fi
    done

    if [ -s "$tmp_txt" ]; then
        echo -e "${GREEN}正在启动批量下载...${RESET}"
        aria2c -c -s 16 -x 16 -k 1M -d "$DOWNLOAD_DIR" -i "$tmp_txt"
    else
        echo -e "${YELLOW}未输入任何链接。${RESET}"
    fi
    rm -f "$tmp_txt"
}

# 主菜单
while true; do
    clear
    STATUS=$(get_aria_status)
    VERSION=$(get_aria_version)

    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}     ◈  aria2 全能下载工具  ◈     ${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN} 核心状态: $STATUS${RESET}"
    echo -e "${GREEN} 当前版本: ${YELLOW}v$VERSION${RESET}"
    echo -e "${GREEN} 保存目录: ${YELLOW}$DOWNLOAD_DIR${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${YELLOW} [环境管理]${RESET}"
    echo -e "${GREEN}  1. 安装 aria2 ${RESET}"
    echo -e "${GREEN}  2. 卸载 aria2${RESET}"
    echo -e "${GREEN}  3. 修改当前自定义保存目录${RESET}"
    echo -e "${GREEN}  4. 显示当前外部 Web(AriaNg)连接所需的 RPC 凭证${RESET}"
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${YELLOW} [下载功能]${RESET}"
    echo -e "${GREEN}  5. HTTP / HTTPS / FTP 常用链接下载 (16线程)${RESET}"
    echo -e "${GREEN}  6. Magnet磁力下载(Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  7. BitTorrent种子下载(Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  8. [PT站专属]种子/链接下载${RESET}"
    echo -e "${GREEN}  9. 批量多链接交互下载${RESET}"
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    
    read -e -p "$PROMPT_CHOICE" choice

    case $choice in
        1) install_or_update_aria2 ;;
        2) uninstall_aria2 ;;
        3) set_download_dir ;;
        4) show_rpc_credentials ;;
        5) download_http ;;
        6) download_magnet ;;
        7) download_torrent ;;
        8) download_pt_pure ;;
        9) download_batch_txt ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac

    echo
    read -p "$PROMPT_CONTINUE"
done

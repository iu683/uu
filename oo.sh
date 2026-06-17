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

get_config_value() {
    local key=$1
    if [ -f "$CONFIG_FILE" ]; then
        grep "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2
    else
        echo ""
    fi
}

get_public_ip() {
    local mode=${1:-"auto"} 
    local ip=""
    
    if [[ "$mode" == "v4" ]]; then
        for url in "https://api.ipify.org" "https://4.ip.sb" "https://checkip.amazonaws.com"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" != *":"* ]] && echo "$ip" && return 0
        done
    elif [[ "$mode" == "v6" ]]; then
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -6 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" && "$ip" == *":"* ]] && echo "$ip" && return 0
        done
    else
        for url in "https://api.ipify.org" "https://4.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 -4 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
        for url in "https://api64.ipify.org" "https://6.ip.sb"; do
            ip=$(wget -qO- --timeout=3 --tries=1 --no-check-certificate "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return 0
        done
    fi
    echo "127.0.0.1" && return 0
}

# 平滑重启系统守护服务
restart_aria_service() {
    if command -v rc-service &>/dev/null && [ -f /etc/init.d/aria2 ]; then
        rc-service aria2 restart
    elif command -v systemctl &>/dev/null && [ -f /etc/systemd/system/aria2.service ]; then
        systemctl daemon-reload
        systemctl restart aria2
    else
        pkill aria2c &>/dev/null
        nohup aria2c --conf-path="$CONFIG_FILE" >/dev/null 2>&1 &
    fi
}

# 核心渲染：写入配置文件
write_aria_config() {
    local path=$1
    local port=$2
    local token=$3
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$path"

    cat <<EOF > "$CONFIG_FILE"
dir=$path
continue=true
max-concurrent-downloads=5
max-connection-per-server=16
min-split-size=10M
split=10
rpc-listen-port=$port
enable-rpc=true
rpc-allow-origin-all=true
rpc-listen-all=true
rpc-secret=$token
file-allocation=none
enable-dht=true
enable-peer-exchange=true
bt-max-peers=128
seed-time=0
EOF
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

    # 1. 交互式自定义配置参数
    echo -e "\n${YELLOW}>>> 开始初始化 Aria2 参数配置 (直接回车可使用推荐默认值)${RESET}"
    
    # 端口自定义
    read -e -p "$(echo -e "${GREEN}请输入 RPC 监听端口 [默认 6800]: ${RESET}")" input_port
    local current_port=${input_port:-6800}

    # 密码自定义
    local default_token=$(date +%s | sha256sum | base64 | head -c 16)
    read -e -p "$(echo -e "${GREEN}请输入 RPC 密钥(Token) [默认随机生成 ${RED}${default_token}${GREEN}]: ${RESET}")" input_token
    local current_token=${input_token:-$default_token}

    # 2. 写入全局配置文件
    write_aria_config "$DOWNLOAD_DIR" "$current_port" "$current_token"

    # 3. 核心保活：智能判断初始化守护系统
    if [ "$is_alpine" = true ] && command -v rc-service &>/dev/null; then
        echo -e "${GREEN}检测到 Alpine 环境，正在注入 OpenRC 服务守护...${RESET}"
        rc-service aria2 stop &>/dev/null
        
        cat <<'EOF' > /etc/init.d/aria2
#!/sbin/openrc-run
description="Aria2 Download Utility"
command="/usr/bin/aria2c"
command_args="--conf-path=/etc/aria2/aria2.conf"
command_background="yes"
pidfile="/run/aria2.pid"
respawn_delay=5
respawn_max=10
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/aria2
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
        pkill aria2c &>/dev/null
        nohup aria2c --conf-path="$CONFIG_FILE" >/dev/null 2>&1 &
    fi

    # 4. 输出 Web 联机凭证
    show_rpc_credentials
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
    local current_token=$(get_config_value "rpc-secret")
    local current_port=$(get_config_value "rpc-listen-port")
    
    if [ -z "$current_token" ]; then
        echo -e "${RED}未发现有效的配置文件，请先执行选项 1 安装/初始化环境！${RESET}"
        return
    fi
    
    local public_ip=$(get_public_ip)
    
    clear
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}           Aria2 远程 Web 连接配置凭证查询           ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 🌐 RPC 地址 (域名/IP) : ${RESET}${YELLOW}http://$public_ip:$current_port/jsonrpc${RESET}"
    echo -e "${GREEN} 🔌 RPC 端口 (Port)    : ${RESET}${YELLOW}$current_port${RESET}"
    echo -e "${GREEN} 🔐 RPC 密钥 (Token)   : ${RESET}${RED}$current_token${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${YELLOW} 👇 提示: 如果公网连接失败，请确保云服务器控制台安全组已放行 TCP 端口: $current_port${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
}

# 独立菜单功能：在线修改核心配置
modify_aria_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误：配置文件不存在，请先执行选项 1 安装并初始化服务！${RESET}"
        return
    fi

    local old_dir=$(get_config_value "dir")
    local old_port=$(get_config_value "rpc-listen-port")
    local old_token=$(get_config_value "rpc-secret")

    clear
    echo -e "${YELLOW}==================================${RESET}"
    echo -e "${YELLOW}       在线修改 Aria2 核心配置       ${RESET}"
    echo -e "${YELLOW}==================================${RESET}"
    echo -e "当前保存目录: ${GREEN}$old_dir${RESET}"
    echo -e "当前 RPC 端口: ${GREEN}$old_port${RESET}"
    echo -e "当前 RPC 密钥: ${GREEN}$old_token${RESET}"
    echo -e "${YELLOW}----------------------------------${RESET}"

    # 1. 修改路径
    read -e -p "$(echo -e "${GREEN}1. 输入新保存路径 (回车保持不变): ${RESET}")" new_dir
    [ -n "$new_dir" ] && old_dir="$new_dir" && mkdir -p "$old_dir"

    # 2. 修改端口
    read -e -p "$(echo -e "${GREEN}2. 输入新 RPC 端口 (回车保持不变): ${RESET}")" new_port
    [ -n "$new_port" ] && old_port="$new_port"

    # 3. 修改 Token
    read -e -p "$(echo -e "${GREEN}3. 输入新 RPC 密钥 (回车保持不变): ${RESET}")" new_token
    [ -n "$new_token" ] && old_token="$new_token"

    # 更新全局变量防止主菜单显示滞后
    DOWNLOAD_DIR="$old_dir"

    # 重新写入并重启服务
    write_aria_config "$old_dir" "$old_port" "$old_token"
    echo -e "${YELLOW}正在平滑应用新配置并重启守护进程...${RESET}"
    restart_aria_service
    
    echo -e "${GREEN}🎉 配置修改成功并已立即生效！${RESET}"
    show_rpc_credentials
}

check_aria_ready() {
    if ! command -v aria2c &>/dev/null; then
        echo -e "${RED}错误：请先选择选项 1 安装 aria2 才能使用下载功能！${RESET}"
        return 1
    fi
    return 0
}

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

download_http() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 HTTP/HTTPS/FTP 下载链接: ${RESET}")" url
    [ -z "$url" ] && return
    aria2c -c -s 16 -x 16 -k 1M -d "$DOWNLOAD_DIR" "$url"
}

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

download_pt_pure() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 PT站专属种子链接 或 .torrent路径: ${RESET}")" pt_target
    [ -z "$pt_target" ] && return
    echo -e "${GREEN}正在启动 PT 纯净下载模式（不注入外源 Tracker）...${RESET}"
    aria2c --seed-time=0 \
           --enable-dht=false \
           --enable-peer-exchange=false \
           -d "$DOWNLOAD_DIR" "$pt_target"
}

download_batch_txt() {
    check_aria_ready || return
    echo -e "${GREEN}请连续输入需要下载的链接（支持普通链接、磁力链接混合输入），每输完一个按一次回车。${RESET}"
    echo -e "${GREEN}输入完毕后，输入英文字母 ${YELLOW}q${GREEN} 即可开始批量下载。${RESET}"
    
    local tmp_txt="/tmp/aria2_urls.txt"
    > "$tmp_txt"
    local count=1
    local has_magnet=false

    while true; do
        read -e -p "$(echo -e "${GREEN}输入第 [${YELLOW}$count${GREEN}] 个链接 (输入 q 开始): ${RESET}")" input_url
        if [ "$input_url" = "q" ] || [ "$input_url" = "Q" ]; then break; fi
        if [ -n "$input_url" ]; then
            # 检测输入流中是否包含磁力链接标识
            if [[ "$input_url" == *"magnet:?"* ]]; then
                has_magnet=true
            fi
            echo "$input_url" >> "$tmp_txt"
            ((count++))
        fi
    done

    if [ -s "$tmp_txt" ]; then
        echo -e "${GREEN}正在分析下载队列...${RESET}"
        
        # 如果队列中有磁力链接，动态抓取最优 Tracker 并作为运行时参数注入
        if [ "$has_magnet" = true ]; then
            local trackers_arg=$(get_dynamic_trackers)
            echo -e "${GREEN}正在启动 BT/磁力 混合批量加速下载模式...${RESET}"
            aria2c --seed-time=0 \
                   --enable-dht=true \
                   --enable-peer-exchange=true \
                   --bt-max-peers=128 \
                   -c -s 16 -x 16 -k 1M \
                   ${trackers_arg:+--bt-tracker="$trackers_arg"} \
                   -d "$DOWNLOAD_DIR" -i "$tmp_txt"
        else
            echo -e "${GREEN}正在启动普通网络链接批量下载...${RESET}"
            aria2c -c -s 16 -x 16 -k 1M -d "$DOWNLOAD_DIR" -i "$tmp_txt"
        fi
    else
        echo -e "${YELLOW}未输入任何链接。${RESET}"
    fi
    rm -f "$tmp_txt"
}


run_AriaNg() {
    clear
    # 用户提供的代理前缀列表
    local GITHUB_PROXY=(
        ''
        'https://v6.gh-proxy.org/'
        'https://gh-proxy.com/'
        'https://hub.glowp.xyz/'
        'https://proxy.vvvv.ee/'
        'https://ghproxy.lvedong.eu.org/'
    )
    
    local RAW_URL="https://raw.githubusercontent.com/sistarry/toolbox/main/Docker/AriaNg.sh"
    local TEMP_SCRIPT="/tmp/nginx_backup_restore_temp.sh"
    local success=false


    # 循环轮询代理列表
    for proxy in "${GITHUB_PROXY[@]}"; do
        local target_url="${proxy}${RAW_URL}"
        if [ -n "$proxy" ]; then
            echo
        else
            echo
        fi

        # 使用 curl 下载，设置 8 秒超时
        if curl -fsSL --connect-timeout 8 "$target_url" -o "$TEMP_SCRIPT"; then
            success=true
            break
        fi
        echo -e "${RED}❌ 当前连接失败，正在切换下一个节点...${RESET}"
    done

    # 判断是否下载成功并执行
    if [ "$success" = true ] && [ -f "$TEMP_SCRIPT" ]; then
        echo
        chmod +x "$TEMP_SCRIPT"
        
        # 真正执行备份恢复脚本
        bash "$TEMP_SCRIPT"
        
        # 执行完毕后清理临时文件
        rm -f "$TEMP_SCRIPT"
    else
        echo -e "${RED}❌ 致命错误：所有 GitHub 代理节点均无法连接，请检查您的 VPS 网络！${RESET}"
    fi
}


# 动态同步当前配置文件的路径显示
if [ -f "$CONFIG_FILE" ]; then
    DOWNLOAD_DIR=$(get_config_value "dir")
fi

# 主菜单
while true; do
    clear
    STATUS=$(get_aria_status)
    VERSION=$(get_aria_version)
    CURRENT_PORT=$(get_config_value "rpc-listen-port")
    [ -z "$CURRENT_PORT" ] && CURRENT_PORT="6800"

    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN}     ◈  Aria2 全能下载工具  ◈     ${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN} 核心状态: $STATUS${RESET}"
    echo -e "${GREEN} 当前版本: ${YELLOW}v$VERSION${RESET}"
    echo -e "${GREEN} 保存目录: ${YELLOW}$DOWNLOAD_DIR${RESET}"
    echo -e "${GREEN} RPC 端口: ${YELLOW}$CURRENT_PORT${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${YELLOW} [环境管理]${RESET}"
    echo -e "${GREEN}  1. 安装 Aria2${RESET}"
    echo -e "${GREEN}  2. 安装 AriaNg${RESET}"
    echo -e "${GREEN}  3. 更改当前运行配置${RESET}"
    echo -e "${GREEN}  4. 查看当前外部 Web(AriaNg)连接RPC凭证${RESET}"
    echo -e "${GREEN}  5. 卸载 Aria2${RESET}"
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${YELLOW} [下载功能]${RESET}"
    echo -e "${GREEN}  6. HTTP / HTTPS / FTP 常用链接下载 (16线程)${RESET}"
    echo -e "${GREEN}  7. Magnet磁力下载(Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  8. BitTorrent种子下载(Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  9. [PT站专属]种子/链接下载${RESET}"
    echo -e "${GREEN} 10. 批量多链接交互下载(HTTP/HTTPS/FTP)${RESET}"
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    
    read -e -p "$PROMPT_CHOICE" choice

    case $choice in
        1) install_or_update_aria2 ;;
        2) run_AriaNg ;;
        3) modify_aria_config ;;
        4) show_rpc_credentials ;;
        5) uninstall_aria2 ;;
        6) download_http ;;
        7) download_magnet ;;
        8) download_torrent ;;
        9) download_pt_pure ;;
        10) download_batch_txt ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac

    echo
    read -p "$PROMPT_CONTINUE"
done

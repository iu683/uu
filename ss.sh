#!/bin/bash
# ========================================
# aria2 系统原生包管理器全能管理与下载工具
# 完美适配 cf.trackerslist.com 官方直连分流源
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 默认保存目录
DOWNLOAD_DIR="/opt/aria2_downloads"
mkdir -p "$DOWNLOAD_DIR"

PROMPT_CHOICE=$(echo -e "${GREEN}请输入选项: ${RESET}")
PROMPT_CONTINUE=$(echo -e "${GREEN}按回车继续...${RESET}")

get_aria_status() {
    if command -v aria2c &>/dev/null; then
        echo -e "${GREEN}运行 (已就绪)${RESET}"
    else
        echo -e "${RED}停止 (未安装)${RESET}"
    fi
}

get_aria_version() {
    if command -v aria2c &>/dev/null; then
        aria2c -v | head -n 1 | awk '{print $3}'
    else
        echo "无"
    fi
}

install_or_update_aria2() {
    if [ "$EUID" -ne 0 ] && [ -f /etc/debian_version ]; then
        echo -e "${RED}错误：请使用 root 权限或 sudo 运行此脚本！${RESET}"
        return
    fi

    echo -e "${GREEN}正在检测系统包管理器环境...${RESET}"
    
    if command -v apt &>/dev/null; then
        echo -e "${GREEN}检测到基于 Debian/Ubuntu 的系统，正在使用 ${YELLOW}apt${GREEN} 进行部署...${RESET}"
        apt update -y
        apt install aria2 curl grep -y
    elif command -v apk &>/dev/null; then
        echo -e "${GREEN}检测到基于 Alpine Linux 的系统，正在使用 ${YELLOW}apk${GREEN} 进行部署...${RESET}"
        apk update
        apk add aria2 curl grep bash
    else
        echo -e "${RED}❌ 抱歉，当前系统既不是 APT 也不支持 APK，无法进行自动化安装。${RESET}"
        return
    fi

    if command -v aria2c &>/dev/null; then
        local NEW_VER=$(get_aria_version)
        echo -e "${GREEN}🎉 aria2 v${NEW_VER} 原生包管理器版成功部署！${RESET}"
    else
        echo -e "${RED}❌ 安装失败，请检查您的软件源或网络连接！${RESET}"
    fi
}

uninstall_aria2() {
    echo -e "${YELLOW}正在清理 aria2 相关程序...${RESET}"
    if command -v apt &>/dev/null; then
        apt remove aria2 -y
        apt autoremove -y
    elif command -v apk &>/dev/null; then
        apk del aria2
    else
        rm -f /usr/local/bin/aria2c /usr/bin/aria2c
    fi
    echo -e "${GREEN}卸载完成。${RESET}"
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

# 【全新升级】使用 Cloudflare CDN 官方格式化分流源，实现毫秒级拉取与无缝注入
get_dynamic_trackers() {
    echo -e "${GREEN}正在通过 Cloudflare CDN 全速获取精选 Tracker 列表...${RESET}" >&2
    
    local trackers=""
    # 依次尝试：精选最佳源 -> 完整全节点源
    local cdn_urls=(
        "https://cf.trackerslist.com/best_aria2.txt"
        "https://cf.trackerslist.com/all_aria2.txt"
    )
    
    for url in "${cdn_urls[@]}"; do
        echo -e "${GREEN}正在连接直连加速节点: ${YELLOW}$url${RESET}" >&2
        # 拉取纯文本并剔除可能存在的首尾空白或空行
        trackers=$(curl -L -s -k -m 4 "$url" | grep -v '^#' | tr -d '\r' | tr '\n' ',' | sed 's/,,*/,/g' | sed 's/^,//;s/,$//')
        
        # 验证抓取到的内容是否包含合法的 tracker 协议前缀
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

# 7. 批量文本链接下载
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

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         aria2 智能系统原生部署与全能下载工具          ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 核心状态: $STATUS${RESET}"
    echo -e "${GREEN} 当前版本: ${YELLOW}v$VERSION${RESET}"
    echo -e "${GREEN} 保存目录: ${YELLOW}$DOWNLOAD_DIR${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} [环境管理]${RESET}"
    echo -e "${GREEN}  1. 安装/更新 aria2 (系统原生 APT / APK 智能识配)${RESET}"
    echo -e "${GREEN}  2. 卸载 aria2 下载器${RESET}"
    echo -e "${GREEN}  3. 修改当前自定义保存目录${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${GREEN} [实用下载功能]${RESET}"
    echo -e "${GREEN}  4. HTTP / HTTPS / FTP 常用链接下载 (16线程)${RESET}"
    echo -e "${GREEN}  5. Magnet 磁力下载 (🔥CF专线Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  6. BitTorrent 种子下载 (🔥CF专线Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  7. 批量多链接交互下载${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${GREEN}  0. 退出脚本${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    
    read -e -p "$PROMPT_CHOICE" choice

    case $choice in
        1) install_or_update_aria2 ;;
        2) uninstall_aria2 ;;
        3) set_download_dir ;;
        4) download_http ;;
        5) download_magnet ;;
        6) download_torrent ;;
        7) download_batch_txt ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac

    echo
    read -p "$PROMPT_CONTINUE"
done

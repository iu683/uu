#!/bin/bash
# ========================================
# aria2 系统原生包管理器全能管理与下载工具
# 支持 APT (Debian/Ubuntu) / APK (Alpine)
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 默认保存目录
DOWNLOAD_DIR="/opt/aria2_downloads"
mkdir -p "$DOWNLOAD_DIR"

# 内置 GitHub 反代加速节点（仅用于拉取 BT 加速 Tracker）
GITHUB_PROXY=(
    ''
    'https://v6.gh-proxy.org/'
    'https://gh-proxy.com/'
    'https://hub.glowp.xyz/'
    'https://proxy.vvvv.ee/'
    'https://ghproxy.lvedong.eu.org/'
)

# 统一定义 Prompt 提示符
PROMPT_CHOICE=$(echo -e "${GREEN}请输入选项: ${RESET}")
PROMPT_CONTINUE=$(echo -e "${GREEN}按回车继续...${RESET}")

# 动态获取 aria2 状态
get_aria_status() {
    if command -v aria2c &>/dev/null; then
        echo -e "${GREEN}运行 (已就绪)${RESET}"
    else
        echo -e "${RED}停止 (未安装)${RESET}"
    fi
}

# 动态获取当前本地安装的 aria2 版本
get_aria_version() {
    if command -v aria2c &>/dev/null; then
        aria2c -v | head -n 1 | awk '{print $3}'
    else
        echo "无"
    fi
}

# 智能识别包管理器并一键安装/更新
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

# 智能卸载
uninstall_aria2() {
    echo -e "${YELLOW}正在清理 aria2 相关程序...${RESET}"
    if command -v apt &>/dev/null; then
        apt remove aria2 -y
        apt autoremove -y
    elif command -v apk &>/dev/null; then
        apk del aria2
    else
        # 兜底清理手动残留
        rm -f /usr/local/bin/aria2c /usr/bin/aria2c
    fi
    echo -e "${GREEN}卸载完成。${RESET}"
}

# 设置保存目录
set_download_dir() {
    read -e -p "$(echo -e "${GREEN}当前保存目录为: ${YELLOW}$DOWNLOAD_DIR${RESET}\n${GREEN}请输入新的保存路径: ${RESET}")" new_dir
    if [ -n "$new_dir" ]; then
        DOWNLOAD_DIR="$new_dir"
        mkdir -p "$DOWNLOAD_DIR"
        echo -e "${GREEN}保存路径已成功修改为: ${YELLOW}$DOWNLOAD_DIR${RESET}"
    else
        echo -e "${YELLOW}输入为空，路径保持不变. ${RESET}"
    fi
}

# 辅助检查 aria2c 是否就绪
check_aria_ready() {
    if ! command -v aria2c &>/dev/null; then
        echo -e "${RED}错误：请先选择选项 1 安装 aria2 才能使用下载功能！${RESET}"
        return 1
    fi
    return 0
}

# 通过自定义的反代代理池，安全且加速地拉取云端最新 Tracker 列表
get_dynamic_trackers() {
    echo -e "${GREEN}正在通过反代节点池拉取最新 BT 加速 Tracker 列表...${RESET}"
    
    local raw_script_path="XIU2/TrackersListCollection/master/tracker.sh"
    local tmp_script="/tmp/aria2_tracker_exec.sh"
    local trackers=""
    local fetch_success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local tracker_url="${proxy}https://raw.githubusercontent.com/${raw_script_path}"
        echo -e "${GREEN}正在尝试连接 Tracker 节点: ${YELLOW}${proxy:-'GitHub官方Raw链接'}${RESET}"
        
        rm -f "$tmp_script"
        curl -L -m 15 "$tracker_url" -o "$tmp_script" 2>/dev/null
        
        if [ -s "$tmp_script" ] && grep -q "Aria2" "$tmp_script"; then
            trackers=$(bash "$tmp_script" cat 2>/dev/null)
            if [ -n "$trackers" ]; then
                fetch_success=true
                break
            fi
        fi
    done

    rm -f "$tmp_script"

    if [ "$fetch_success" = true ]; then
        echo -e "${GREEN}Tracker 列表获取成功并已成功注入！正在调动 P2P 网络...${RESET}"
        echo "$trackers"
    else
        echo -e "${YELLOW}警告：所有反代代理节点均拉取 Tracker 超时，将转入常规多线程 DHT 模式。${RESET}"
        echo ""
    fi
}

# 4. 普通网络链接下载
download_http() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 HTTP/HTTPS/FTP 下载链接: ${RESET}")" url
    [ -z "$url" ] && return
    aria2c -c -s 16 -x 16 -k 1M -d "$DOWNLOAD_DIR" "$url"
}

# 5. 磁力链接下载 (主程序 + Tracker 双重反代加速)
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

# 6. 种子文件下载 (主程序 + Tracker 双重反代加速)
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
    echo -e "${GREEN}  5. Magnet 磁力下载 (🔥反代Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  6. BitTorrent 种子下载 (🔥反代Tracker+128多线程加速)${RESET}"
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

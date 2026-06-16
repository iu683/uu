#!/bin/bash
# ========================================
# aria2 GitHub 最新版全能管理与下载工具
# 菜单字体绿色版 + 核心&Tracker全线反代加速版
# ========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# 默认保存目录
DOWNLOAD_DIR="/opt/aria2_downloads"
mkdir -p "$DOWNLOAD_DIR"

# 内置 GitHub 反代加速节点
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

# 从 GitHub API 获取最新的 release 版本号
get_latest_release() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/aria2/aria2/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_version" ]; then
        echo "获取失败"
    else
        echo "$latest_version" | sed 's/release-//g' | sed 's/v//g'
    fi
}

# 核心下载与安装函数 (包含智能节点轮询)
install_or_update_aria2() {
    local mode=$1
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 权限或 sudo 运行此脚本！${RESET}"
        return
    fi

    echo -e "${GREEN}正在拉取 GitHub 获取最新版本信息...${RESET}"
    local LATEST_VERSION=$(get_latest_release)
    
    if [ "$LATEST_VERSION" = "获取失败" ]; then
        echo -e "${RED}❌ 无法连接到 GitHub API，请稍后再试。${RESET}"
        return
    fi

    if [ "$mode" = "update" ]; then
        local CURRENT_VERSION=$(get_aria_version)
        if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
            echo -e "${GREEN}当前已是最新版本 v${CURRENT_VERSION}，无需更新！${RESET}"
            return
        fi
        echo -e "${YELLOW}检测到新版本 v${LATEST_VERSION} (当前本地版本: v${CURRENT_VERSION})${RESET}"
    fi

    apt update -y &>/dev/null
    apt install curl tar bzip2 -y &>/dev/null

    local ARCH=$(uname -m)
    local FILE_SUFFIX=""
    if [ "$ARCH" = "x86_64" ]; then
        FILE_SUFFIX="linux-gnu-64bit-build1.tar.bz2"
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        FILE_SUFFIX="linux-gnu-arm64-build1.tar.bz2"
    else
        echo -e "${RED}❌ 暂不支持当前架构 ($ARCH)。${RESET}"
        return
    fi

    local RAW_PATH="aria2/aria2/releases/download/release-${LATEST_VERSION}/aria2-${LATEST_VERSION}-${FILE_SUFFIX}"
    local TMP_DIR="/tmp/aria2_pro_download"
    mkdir -p "$TMP_DIR"
    local download_success=false

    for proxy in "${GITHUB_PROXY[@]}"; do
        local download_url="${proxy}https://github.com/${RAW_PATH}"
        echo -e "${GREEN}正在尝试下载主程序，节点: ${YELLOW}${proxy:-'GitHub官方原始链接'}${RESET}"
        curl -L -m 30 "$download_url" -o "$TMP_DIR/aria2.tar.bz2"
        
        if [ -s "$TMP_DIR/aria2.tar.bz2" ] && bzip2 -t "$TMP_DIR/aria2.tar.bz2" &>/dev/null; then
            echo -e "${GREEN}解压测试通过，主程序下载成功！${RESET}"
            download_success=true
            break
        else
            echo -e "${RED}当前节点下载失败，正在切换...${RESET}"
            rm -f "$TMP_DIR/aria2.tar.bz2"
        fi
    done

    if [ "$download_success" = false ]; then
        echo -e "${RED}❌ 所有内置代理节点均尝试失败！${RESET}"
        rm -rf "$TMP_DIR"
        return
    fi

    echo -e "${GREEN}正在解压并覆盖部署二进制文件...${RESET}"
    cd "$TMP_DIR" || return
    tar -xjf aria2.tar.bz2
    
    local BINARY_PATH=$(find . -maxdepth 2 -name "aria2c" -type f)
    if [ -n "$BINARY_PATH" ]; then
        apt remove aria2 -y &>/dev/null
        rm -f /usr/bin/aria2c
        mv "$BINARY_PATH" /usr/local/bin/aria2c
        chmod a+rx /usr/local/bin/aria2c
        echo -e "${GREEN}🎉 aria2 v${LATEST_VERSION} 成功部署！${RESET}"
    else
        echo -e "${RED}❌ 压缩包中未检索到可执行文件。${RESET}"
    fi
    rm -rf "$TMP_DIR"
}

uninstall_aria2() {
    echo -e "${YELLOW}正在清理 aria2 相关程序...${RESET}"
    apt remove aria2 -y &>/dev/null
    rm -f /usr/local/bin/aria2c
    rm -f /usr/bin/aria2c
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
        echo -e "${YELLOW}输入为空，路径保持不变。${RESET}"
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

# 【升级核心】通过自定义的反代代理池，安全且加速地拉取云端最新 Tracker 列表
get_dynamic_trackers() {
    echo -e "${GREEN}正在通过反代节点池拉取最新 BT 加速 Tracker 列表...${RESET}"
    
    local raw_script_path="XIU2/TrackersListCollection/master/tracker.sh"
    local tmp_script="/tmp/aria2_tracker_exec.sh"
    local trackers=""
    local fetch_success=false

    # 遍历代理节点来下载并运行 tracker.sh
    for proxy in "${GITHUB_PROXY[@]}"; do
        local tracker_url="${proxy}https://raw.githubusercontent.com/${raw_script_path}"
        echo -e "${GREEN}正在尝试连接 Tracker 节点: ${YELLOW}${proxy:-'GitHub官方Raw链接'}${RESET}"
        
        # 强制下载脚本到本地
        rm -f "$tmp_script"
        curl -L -m 15 "$tracker_url" -o "$tmp_script" 2>/dev/null
        
        # 验证下载的是否是有效的 bash 脚本（而不是被墙的报错网页内容）
        if [ -s "$tmp_script" ] && grep -q "Aria2" "$tmp_script"; then
            # 运行本地脚本并将结果（cat 模式输出的一行文本）存入变量
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

# 5. 普通网络链接下载
download_http() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 HTTP/HTTPS/FTP 下载链接: ${RESET}")" url
    [ -z "$url" ] && return
    aria2c -c -s 16 -x 16 -k 1M -d "$DOWNLOAD_DIR" "$url"
}

# 6. 磁力链接下载 (主程序 + Tracker 双重反代加速)
download_magnet() {
    check_aria_ready || return
    read -e -p "$(echo -e "${GREEN}请输入 Magnet 磁力链接: ${RESET}")" magnet
    [ -z "$magnet" ] && return
    
    local trackers_arg=$(get_dynamic_trackers)
    
    # 注入 Tracker + 128 高连接数 + DHT 网络全开
    aria2c --seed-time=0 \
           --enable-dht=true \
           --enable-peer-exchange=true \
           --bt-max-peers=128 \
           --max-connection-per-server=16 \
           ${trackers_arg:+--bt-tracker="$trackers_arg"} \
           -d "$DOWNLOAD_DIR" "$magnet"
}

# 7. 种子文件下载 (主程序 + Tracker 双重反代加速)
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

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}         aria2 智能管理与全能下载器 PRO               ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 核心状态: $STATUS${RESET}"
    echo -e "${GREEN} 当前版本: ${YELLOW}v$VERSION${RESET}"
    echo -e "${GREEN} 保存目录: ${YELLOW}$DOWNLOAD_DIR${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} [环境管理]${RESET}"
    echo -e "${GREEN}  1. 安装 aria2 (智能代理抓取 GitHub 最新版)${RESET}"
    echo -e "${GREEN}  2. 检查并更新 aria2 (智能代理版)${RESET}"
    echo -e "${GREEN}  3. 卸载 aria2 下载器${RESET}"
    echo -e "${GREEN}  4. 修改当前自定义保存目录${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${GREEN} [实用下载功能]${RESET}"
    echo -e "${GREEN}  5. HTTP / HTTPS / FTP 常用链接下载 (16线程)${RESET}"
    echo -e "${GREEN}  6. Magnet 磁力下载 (🔥反代Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  7. BitTorrent 种子下载 (🔥反代Tracker+128多线程加速)${RESET}"
    echo -e "${GREEN}  8. 批量多链接交互下载${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${GREEN}  0. 退出脚本${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    
    read -e -p "$PROMPT_CHOICE" choice

    case $choice in
        1) install_or_update_aria2 "install" ;;
        2) install_or_update_aria2 "update" ;;
        3) uninstall_aria2 ;;
        4) set_download_dir ;;
        5) download_http ;;
        6) download_magnet ;;
        7) download_torrent ;;
        8) download_batch_txt ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac

    echo
    read -p "$PROMPT_CONTINUE"
done

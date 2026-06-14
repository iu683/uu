#!/bin/bash
# ========================================
# yt-dlp 一键管理脚本 PRO 
# ========================================

VIDEO_DIR="/opt/yt-dlp"
URL_FILE="$VIDEO_DIR/urls.txt"
COOKIE_FILE="$VIDEO_DIR/cookies.txt"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

mkdir -p "$VIDEO_DIR"

# 自动构建 Cookie 参数
get_cookie_args() {
    if [ -f "$COOKIE_FILE" ]; then
        echo "--cookies $COOKIE_FILE"
    else
        echo ""
    fi
}

install_yt() {
    echo -e "${GREEN}正在安装 yt-dlp 及其依赖 (包含 JS 运行环境)...${RESET}"
    apt update -y
    # 安装 ffmpeg, curl, nano 之外，额外安装 quickjs 作为 YouTube 的 JS 运行环境
    apt install -y ffmpeg curl nano quickjs
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
    chmod a+rx /usr/local/bin/yt-dlp
    echo -e "${GREEN}安装完成！${RESET}"
}

update_yt() {
    echo -e "${GREEN}正在更新 yt-dlp...${RESET}"
    yt-dlp -U
}

uninstall_yt() {
    rm -f /usr/local/bin/yt-dlp
    rm -rf /opt/yt-dlp
    echo -e "${GREEN}已卸载 yt-dlp${RESET}"
    exit 0
}

download_single() {
    read -e -p "$(echo -e ${GREEN}请输入视频链接: ${RESET})" url
    COOKIE_ARGS=$(get_cookie_args)
    yt-dlp -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        $COOKIE_ARGS \
        --write-subs --sub-langs all \
        --write-thumbnail --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites "$url"
}

download_batch() {
    if [ ! -f "$URL_FILE" ]; then
        echo -e "# 一行一个视频链接" > "$URL_FILE"
    fi
    nano "$URL_FILE"
    COOKIE_ARGS=$(get_cookie_args)
    yt-dlp -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        $COOKIE_ARGS \
        --write-subs --sub-langs all \
        --write-thumbnail --embed-thumbnail \
        --write-info-json \
        -a "$URL_FILE" \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
}

download_custom() {
    read -e -p "$(echo -e ${GREEN}请输入完整 yt-dlp 参数（不含 yt-dlp）: ${RESET})" custom
    COOKIE_ARGS=$(get_cookie_args)
    yt-dlp -P "$VIDEO_DIR" $COOKIE_ARGS $custom \
        --write-subs --sub-langs all \
        --write-thumbnail --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
}

download_mp3() {
    read -e -p "$(echo -e ${GREEN}请输入视频链接: ${RESET})" url
    COOKIE_ARGS=$(get_cookie_args)
    yt-dlp -P "$VIDEO_DIR" -x --audio-format mp3 \
        $COOKIE_ARGS \
        --write-thumbnail --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites "$url"
}

delete_video() {
    echo -e "${GREEN}当前视频目录：${RESET}"
    ls "$VIDEO_DIR"
    read -e -p "$(echo -e ${GREEN}请输入要删除的目录名称: ${RESET})" name
    rm -rf "$VIDEO_DIR/$name"
    echo -e "${GREEN}已删除${RESET}"
}

show_list() {
    echo -e "${GREEN}已下载视频列表：${RESET}"
    ls -td "$VIDEO_DIR"/*/ 2>/dev/null || echo -e "${GREEN}暂无视频${RESET}"
}

while true; do
    clear
    # 检查安装状态与获取版本号
    if [ -x "/usr/local/bin/yt-dlp" ]; then
        STATUS="${YELLOW}已安装${RESET}"
        VERSION_NUM=$(/usr/local/bin/yt-dlp --version 2>/dev/null)
        VERSION="${YELLOW}${VERSION_NUM}${RESET}"
    else
        STATUS="${RED}未安装${RESET}"
        VERSION="${RED}--${RESET}"
    fi

    # 检查 Cookie 状态
    if [ -f "$COOKIE_FILE" ]; then
        COOKIE_STATUS="${GREEN}已载入 (cookies.txt)${RESET}"
    else
        COOKIE_STATUS="${RED}未检测到 (建议配置)${RESET}"
    fi

    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}             yt-dlp 管理工具                     ${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN} 状态: $STATUS    |   当前版本: $VERSION${RESET}"
    echo -e "${GREEN} Cookie 状态: $COOKIE_STATUS${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    echo -e "${GREEN}  1. 安装 yt-dlp${RESET}"
    echo -e "${GREEN}  2. 更新 yt-dlp${RESET}"
    echo -e "${GREEN}  3. 卸载 yt-dlp${RESET}"
    echo -e "${GREEN}  5. 单个视频下载${RESET}"
    echo -e "${GREEN}  6. 批量视频下载${RESET}"
    echo -e "${GREEN}  7. 自定义参数下载${RESET}"
    echo -e "${GREEN}  8. 下载为 MP3${RESET}"
    echo -e "${GREEN}  9. 删除视频目录${RESET}"
    echo -e "${GREEN} 10. 查看下载列表${RESET}"
    echo -e "${GREEN}  0. 退出${RESET}"
    echo -e "${GREEN}=================================================${RESET}"
    read -e -p "$(echo -e ${GREEN}请输入选项: ${RESET})" choice

    case $choice in
        1) install_yt ;;
        2) update_yt ;;
        3) uninstall_yt ;;
        5) download_single ;;
        6) download_batch ;;
        7) download_custom ;;
        8) download_mp3 ;;
        9) delete_video ;;
        10) show_list ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}" ;;
    esac

    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
done

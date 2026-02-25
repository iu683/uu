#!/bin/bash
# ========================================
# yt-dlp 一键管理脚本 PRO
# 菜单字体绿色版
# ========================================

VIDEO_DIR="/opt/yt-dlp"
URL_FILE="$VIDEO_DIR/urls.txt"

GREEN="\033[32m"
RESET="\033[0m"

mkdir -p "$VIDEO_DIR"

install_yt() {
    echo -e "${GREEN}正在安装 yt-dlp...${RESET}"
    apt update -y
    apt install -y ffmpeg curl nano
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
    echo -e "${GREEN}已卸载 yt-dlp${RESET}"
}

download_single() {
    read -e -p "$(echo -e ${GREEN}请输入视频链接: ${RESET})" url
    yt-dlp -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
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
    yt-dlp -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        --write-subs --sub-langs all \
        --write-thumbnail --embed-thumbnail \
        --write-info-json \
        -a "$URL_FILE" \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
}

download_custom() {
    read -e -p "$(echo -e ${GREEN}请输入完整 yt-dlp 参数（不含 yt-dlp）: ${RESET})" custom
    yt-dlp -P "$VIDEO_DIR" $custom \
        --write-subs --sub-langs all \
        --write-thumbnail --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
}

download_mp3() {
    read -e -p "$(echo -e ${GREEN}请输入视频链接: ${RESET})" url
    yt-dlp -P "$VIDEO_DIR" -x --audio-format mp3 \
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
    if [ -x "/usr/local/bin/yt-dlp" ]; then
        STATUS="${GREEN}已安装${RESET}"
    else
        STATUS="${GREEN}未安装${RESET}"
    fi

    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}    yt-dlp 管理工具 状态: $STATUS${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 1. 安装 yt-dlp${RESET}"
    echo -e "${GREEN} 2. 更新 yt-dlp${RESET}"
    echo -e "${GREEN} 3. 卸载 yt-dlp${RESET}"
    echo -e "${GREEN} 5. 单个视频下载${RESET}"
    echo -e "${GREEN} 6. 批量视频下载${RESET}"
    echo -e "${GREEN} 7. 自定义参数下载${RESET}"
    echo -e "${GREEN} 8. 下载为 MP3${RESET}"
    echo -e "${GREEN} 9. 删除视频目录${RESET}"
    echo -e "${GREEN}10. 查看下载列表${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
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
        *) echo -e "${GREEN}无效选项${RESET}" ;;
    esac

    echo
    read -p "$(echo -e ${GREEN}按回车继续...${RESET})"
done

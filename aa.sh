#!/bin/bash
# ========================================
# yt-dlp 一键管理脚本 PRO+ (极致加速防风控版)
# 菜单字体绿色版
# ========================================

VIDEO_DIR="/opt/yt-dlp"
URL_FILE="$VIDEO_DIR/urls.txt"
COOKIE_FILE="/media/cookies.txt"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

mkdir -p "$VIDEO_DIR"

# 统一定义带颜色的 Prompt 提示符，解决 read -p 兼容性问题
PROMPT_CHOICE=$(echo -e "${GREEN}请输入选项: ${RESET}")
PROMPT_URL=$(echo -e "${GREEN}请输入视频链接: ${RESET}")
PROMPT_CUSTOM=$(echo -e "${GREEN}请输入完整 yt-dlp 参数（不含 yt-dlp）: ${RESET}")
PROMPT_DEL=$(echo -e "${GREEN}请输入要删除的目录名称: ${RESET}")
PROMPT_CONTINUE=$(echo -e "${GREEN}按回车继续...${RESET}")

# 自动检测并获取 Cookies 参数
get_cookie_args() {
    if [ -f "$COOKIE_FILE" ]; then
        echo "--cookies $COOKIE_FILE"
    else
        echo ""
    fi
}

install_yt() {
    echo -e "${GREEN}正在安装 yt-dlp、Node.js 及多线程依赖...${RESET}"
    apt update -y
    apt install -y ffmpeg curl nano aria2 nodejs

    # 下载最新版 yt-dlp
    curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
    chmod a+rx /usr/local/bin/yt-dlp

    # 配置永久识别 Node.js 环境（防止 YouTube 算法风控）
    mkdir -p ~/.config/yt-dlp
    echo '--js-runtimes node:/usr/bin/node' > ~/.config/yt-dlp/config

    echo -e "${GREEN}安装与永久环境配置完成！${RESET}"
}

update_yt() {
    echo -e "${GREEN}正在更新 yt-dlp...${RESET}"
    yt-dlp -U
}

uninstall_yt() {
    rm -f /usr/local/bin/yt-dlp
    rm -rf /opt/yt-dlp
    rm -rf ~/.config/yt-dlp
    echo -e "${GREEN}已卸载 yt-dlp 及相关配置文件${RESET}"
    exit 0
}

download_single() {
    read -e -p "$PROMPT_URL" url
    [ -z "$url" ] && return
    
    # 组合多线程与Cookies参数
    yt-dlp $(get_cookie_args) \
        --external-downloader aria2c --external-downloader-args "-x 16 -s 16 -k 1M" \
        -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        --write-subs --sub-langs all \
        --write-thumbnail --convert-thumbnails jpg --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites "$url"
}

download_batch() {
    if [ ! -f "$URL_FILE" ]; then
        echo "# 一行一个视频链接" > "$URL_FILE"
    fi
    nano "$URL_FILE"
    
    yt-dlp $(get_cookie_args) \
        --external-downloader aria2c --external-downloader-args "-x 16 -s 16 -k 1M" \
        -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        --write-subs --sub-langs all \
        --write-thumbnail --convert-thumbnails jpg --embed-thumbnail \
        --write-info-json \
        -a "$URL_FILE" \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
}

download_custom() {
    read -e -p "$PROMPT_CUSTOM" custom
    [ -z "$custom" ] && return
    
    yt-dlp $(get_cookie_args) -P "$VIDEO_DIR" $custom \
        --write-subs --sub-langs all \
        --write-thumbnail --convert-thumbnails jpg --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
}

download_mp3() {
    read -e -p "$PROMPT_URL" url
    [ -z "$url" ] && return
    
    yt-dlp $(get_cookie_args) \
        --external-downloader aria2c --external-downloader-args "-x 16 -s 16 -k 1M" \
        -P "$VIDEO_DIR" -x --audio-format mp3 --audio-quality 0 \
        --write-thumbnail --convert-thumbnails jpg --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites "$url"
}

delete_video() {
    echo -e "${GREEN}当前视频目录：${RESET}"
    ls "$VIDEO_DIR"
    read -e -p "$PROMPT_DEL" name
    [ -z "$name" ] && return
    
    if [ -d "$VIDEO_DIR/$name" ]; then
        rm -rf "$VIDEO_DIR/$name"
        echo -e "${GREEN}已成功删除目录: $name${RESET}"
    else
        echo -e "${RED}未找到该目录！${RESET}"
    fi
}

show_list() {
    echo -e "${GREEN}已下载视频列表：${RESET}"
    if [ -d "$VIDEO_DIR" ] && [ "$(ls -A $VIDEO_DIR)" ]; then
        ls -td "$VIDEO_DIR"/*/ 2>/dev/null | sed "s|$VIDEO_DIR/||g"
    else
        echo -e "${YELLOW}暂无视频${RESET}"
    fi
}

while true; do
    clear
    if [ -x "/usr/local/bin/yt-dlp" ]; then
        STATUS="${GREEN}已安装${RESET}"
    else
        STATUS="${RED}未安装${RESET}"
    fi

    # 检测 Cookies 状态赋予人性化提示
    if [ -f "$COOKIE_FILE" ]; then
        COOKIE_STATUS="${GREEN}已就绪 (/media/cookies.txt)${RESET}"
    else
        COOKIE_STATUS="${YELLOW}未配置 (如遇风控请上传至 /media/cookies.txt)${RESET}"
    fi

    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}          yt-dlp 高级管理脚本 PRO+                  ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 核心状态: $STATUS${RESET}"
    echo -e "${GREEN} Cookie状态: $COOKIE_STATUS${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN} 1. 安装环境 (含 yt-dlp、Node.js、Aria2加速)${RESET}"
    echo -e "${GREEN} 2. 更新 yt-dlp${RESET}"
    echo -e "${GREEN} 3. 卸载 yt-dlp${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${GREEN} 5. 单个视频下载 (16线程极速)${RESET}"
    echo -e "${GREEN} 6. 批量视频下载 (编辑 urls.txt)${RESET}"
    echo -e "${GREEN} 7. 自定义参数下载${RESET}"
    echo -e "${GREEN} 8. 下载为最佳音质 MP3${RESET}"
    echo -e "${GREEN}----------------------------------------------------${RESET}"
    echo -e "${GREEN} 9. 删除视频目录${RESET}"
    echo -e "${GREEN} 10. 查看下载列表${RESET}"
    echo -e "${GREEN} 0. 退出脚本${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    
    read -e -p "$PROMPT_CHOICE" choice

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
        *) echo -e "${RED}无效选项，请重新输入！${RESET}" ;;
    esac

    echo
    read -p "$PROMPT_CONTINUE"
done

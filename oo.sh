#!/bin/bash
# ========================================
# yt-dlp 一键管理脚本 (支持 Alpine & Debian/Ubuntu)
# ========================================

VIDEO_DIR="/opt/yt-dlp"
URL_FILE="$VIDEO_DIR/urls.txt"
COOKIE_FILE="$VIDEO_DIR/cookies.txt"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

mkdir -p "$VIDEO_DIR"

# 统一定义带颜色的 Prompt 提示符
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

# 动态获取 yt-dlp 版本
get_yt_version() {
    if command -v yt-dlp &>/dev/null; then
        yt-dlp --version 2>/dev/null || echo "未知版本"
    else
        echo "无"
    fi
}

install_yt() {
    echo -e "${GREEN}开始检查并安装所需组件...${RESET}"
    
    # 检测包管理器
    local pkg_manager=""
    if command -v apk &>/dev/null; then
        pkg_manager="apk"
    elif command -v apt &>/dev/null; then
        pkg_manager="apt"
    else
        echo -e "${RED}未检测到受支持的包管理器 (apk/apt)，请手动安装依赖！${RESET}"
        return 1
    fi

    # 待检查的命令列表与对应的包名
    local deps=("ffmpeg" "curl" "node" "aria2c")
    local to_install=()

    # 针对不同系统映射包名
    for dep in "${deps[@]}"; do
        if command -v "$dep" &>/dev/null; then
            echo -e "检查 ${YELLOW}$dep${RESET} ... [${GREEN}已安装，跳过${RESET}]"
        else
            echo -e "检查 ${YELLOW}$dep${RESET} ... [${RED}未安装${RESET}]"
            if [ "$pkg_manager" = "apk" ]; then
                # Alpine 包名映射
                case "$dep" in
                    "node") to_install+=("nodejs") ;;
                    "aria2c") to_install+=("aria2") ;;
                    *) to_install+=("$dep") ;;
                esac
            else
                # Apt 包名映射
                case "$dep" in
                    "node") to_install+=("nodejs") ;;
                    "aria2c") to_install+=("aria2") ;;
                    *) to_install+=("$dep") ;;
                esac
            fi
        fi
    done

    # 执行必要的安装
    if [ ${#to_install[@]} -ne 0 ]; then
        echo -e "${GREEN}正在通过 $pkg_manager 安装缺失组件: ${to_install[*]}...${RESET}"
        if [ "$pkg_manager" = "apk" ]; then
            apk update
            # Alpine 默认可能缺少 bash 和 python3，yt-dlp 运行必须依赖 python3
            apk add bash python3 "${to_install[@]}"
        else
            apt update -y
            apt install -y "${to_install[@]}"
        fi
    else
        echo -e "${GREEN}所有系统依赖组件均已就绪。${RESET}"
    fi

    # 检查或安装 yt-dlp 本体
    if ! command -v yt-dlp &>/dev/null; then
        echo -e "${GREEN}正在下载安装 yt-dlp...${RESET}"
        # 统一安装到 /usr/local/bin
        curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
        chmod a+rx /usr/local/bin/yt-dlp
    else
        echo -e "${GREEN}yt-dlp 主程序已存在，如需更新请在菜单选择选项 2。${RESET}"
    fi

    # 配置永久识别 Node.js 环境（兼容 Alpine 和 Debian 的 node 路径）
    NODE_PATH=$(command -v node)
    mkdir -p ~/.config/yt-dlp
    echo "--js-runtimes node:$NODE_PATH" > ~/.config/yt-dlp/config

    echo -e "${GREEN}环境检查与配置全部完成！${RESET}"
}

update_yt() {
    echo -e "${GREEN}正在更新 yt-dlp...${RESET}"
    if command -v yt-dlp &>/dev/null; then
        yt-dlp -U
    else
        echo -e "${RED}未检测到 yt-dlp，请先执行安装！${RESET}"
    fi
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
    
    yt-dlp $(get_cookie_args) \
        --external-downloader aria2c \
        --downloader-args "aria2c:-x 16 -s 16 -k 1M" \
        -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        --write-subs --sub-langs all \
        --write-thumbnail --convert-thumbnails jpg --embed-thumbnail \
        --write-info-json \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites "$url"
}

download_batch() {
    echo -e "${GREEN}====================================================${RESET}"
    echo -e "${GREEN}                进入交互式批量下载模式               ${RESET}"
    echo -e "${GREEN} 请连续输入视频链接，每输完一个按一次回车。         ${RESET}"
    echo -e "${GREEN} 输入完毕后，输入英文字母 ${YELLOW}q${GREEN} 即可开始下载。         ${RESET}"
    echo -e "${GREEN}====================================================${RESET}"
    
    # 清空或初始化链接临时文件
    > "$URL_FILE"
    
    local count=1
    while true; do
        read -e -p "$(echo -e "${GREEN}请输入第 [${YELLOW}$count${GREEN}] 个链接 (输入 q 开始下载): ${RESET}")" input_url
        if [ "$input_url" = "q" ] || [ "$input_url" = "Q" ]; then
            break
        fi
        if [ -n "$input_url" ]; then
            echo "$input_url" >> "$URL_FILE"
            ((count++))
        fi
    done
    
    # 检查是否有有效输入
    if [ ! -s "$URL_FILE" ]; then
        echo -e "${YELLOW}未输入任何链接，已取消批量下载。${RESET}"
        return
    fi
    
    echo -e "${GREEN}正在开始批量下载，共 $(($count-1)) 个任务...${RESET}"
    
    yt-dlp $(get_cookie_args) \
        --external-downloader aria2c \
        --downloader-args "aria2c:-x 16 -s 16 -k 1M" \
        -P "$VIDEO_DIR" -f "bv*+ba/b" --merge-output-format mp4 \
        --write-subs --sub-langs all \
        --write-thumbnail --convert-thumbnails jpg --embed-thumbnail \
        --write-info-json \
        -a "$URL_FILE" \
        -o "$VIDEO_DIR/%(title)s/%(title)s.%(ext)s" \
        --no-overwrites --no-post-overwrites
        
    # 下载完成后清理临时链接文件
    rm -f "$URL_FILE"
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
        --external-downloader aria2c \
        --downloader-args "aria2c:-x 16 -s 16 -k 1M" \
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
    if command -v yt-dlp &>/dev/null; then
        STATUS="${GREEN}运行${RESET}"
    else
        STATUS="${RED}停止${RESET}"
    fi

    # 获取实时版本号
    VERSION=$(get_yt_version)

    # 检测统一路径下的 Cookies 状态
    if [ -f "$COOKIE_FILE" ]; then
        COOKIE_STATUS="${GREEN}已就绪 ($COOKIE_FILE)${RESET}"
    else
        COOKIE_STATUS="${YELLOW}未配置 (请上传至 $COOKIE_FILE)${RESET}"
    fi

    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN}     ◈   yt-dlp 管理面板   ◈     ${RESET}"
    echo -e "${GREEN}=================================${RESET}"
    echo -e "${GREEN} 核心状态: $STATUS${RESET}"
    echo -e "${GREEN} 软件版本: ${YELLOW}$VERSION${RESET}"
    echo -e "${GREEN} 保存目录: ${YELLOW}$VIDEO_DIR${RESET}"
    echo -e "${GREEN} Cookie状态: $COOKIE_STATUS${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    echo -e "${GREEN} 1. 安装 yt-dlp${RESET}"
    echo -e "${GREEN} 2. 更新 yt-dlp${RESET}"
    echo -e "${GREEN} 3. 卸载 yt-dlp${RESET}"
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${GREEN} 5. 单个视频下载 (16线程极速)${RESET}"
    echo -e "${GREEN} 6. 批量视频下载 (交互式输入多链接)${RESET}"
    echo -e "${GREEN} 7. 自定义参数下载${RESET}"
    echo -e "${GREEN} 8. 下载为最佳音质 MP3${RESET}"
    echo -e "${GREEN}----------------------------------${RESET}"
    echo -e "${GREEN} 9. 删除视频目录${RESET}"
    echo -e "${GREEN}10. 查看下载列表${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}==================================${RESET}"
    
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

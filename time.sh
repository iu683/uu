#!/bin/bash
# 通用时区管理脚本
# 兼容 systemd (timedatectl) 和 Alpine (OpenRC)
# 自动在 Alpine 上安装 tzdata

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"


# 在 Alpine 上安装 tzdata
install_tzdata_alpine() {
    if [[ -f /etc/alpine-release ]]; then
        if ! apk info | grep -q tzdata; then
            echo -e "${GREEN}检测到 Alpine，正在安装 tzdata…${RESET}"
            apk update && apk add tzdata
        fi
    fi
}

# 获取当前时区
get_timezone() {
    if command -v timedatectl &>/dev/null; then
        timedatectl show -p Timezone --value
    elif [[ -f /etc/timezone ]]; then
        cat /etc/timezone
    elif [[ -L /etc/localtime ]]; then
        readlink /etc/localtime | sed 's#.*/zoneinfo/##'
    else
        echo "未知"
    fi
}

# 设置时区
set_timezone() {
    local zone="$1"

    # 特殊处理 UTC
    if [[ "$zone" == "UTC" ]]; then
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone UTC
        elif [[ -f /etc/alpine-release ]]; then
            install_tzdata_alpine
            echo "UTC" > /etc/timezone
            ln -sf "/usr/share/zoneinfo/UTC" /etc/localtime 2>/dev/null || :
        else
            echo -e "${RED}❌ 不支持的系统，请手动设置时区${RESET}"
            return 1
        fi
        echo -e "${GREEN}✅ 时区已设置为 UTC${RESET}"
        return
    fi

    # 检查时区文件是否存在
    if [[ ! -f "/usr/share/zoneinfo/$zone" ]]; then
        if [[ -f /etc/alpine-release ]]; then
            install_tzdata_alpine
        fi
        if [[ ! -f "/usr/share/zoneinfo/$zone" ]]; then
            echo -e "${RED}❌ 时区不存在: $zone${RESET}"
            return 1
        fi
    fi

    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$zone"
    elif [[ -f /etc/alpine-release ]]; then
        echo "$zone" > /etc/timezone
        ln -sf "/usr/share/zoneinfo/$zone" /etc/localtime
    else
        echo -e "${RED}❌ 不支持的系统，请手动设置时区${RESET}"
        return 1
    fi
    echo -e "${GREEN}✅ 时区已设置为 $zone${RESET}"
}

# 菜单显示
show_menu() {
    clear
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN}         🌍 通用时区管理脚本${RESET}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${GREEN} 当前时区:${YELLOW} $(get_timezone)${RESET}"
    echo -e "${GREEN} 1) 设置为 Asia/Shanghai (中国)${RESET}"
    echo -e "${GREEN} 2) 设置为 America/New_York(美国)${RESET}"
    echo -e "${GREEN} 3) 设置为 Europe/London(英国)${RESET}"
    echo -e "${GREEN} 4) 自定义时区${RESET}"
    echo -e "${GREEN} 0) 退出${RESET}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# 主循环
while true; do
    show_menu
    echo -en "${GREEN}请输入选项: ${RESET}"
    read choice
    case "$choice" in
        1)
            set_timezone "Asia/Shanghai"
            read -p "按回车继续..."
            ;;
        2)
            set_timezone "America/New_York"
            read -p "按回车继续..."
            ;;
        3)
            set_timezone "Europe/London"
            read -p "按回车继续..."
            ;;
        4)
            echo -en "${GREEN}请输入时区 (例如 Asia/Tokyo): ${RESET}"
            read tz
            set_timezone "$tz"
            read -p "按回车继续..."
            ;;
        0)
            echo -e "${GREEN}已退出${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重试${RESET}"
            sleep 1
            ;;
    esac
done

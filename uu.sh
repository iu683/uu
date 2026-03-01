#!/bin/bash
export LANG=en_US.UTF-8

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

green(){ echo -e "${GREEN}$1${RESET}"; }
red(){ echo -e "${RED}$1${RESET}"; }
yellow(){ echo -e "${YELLOW}$1${RESET}"; }

# =========================
# 检查 np 是否存在
# =========================
check_np(){
    if ! command -v np &>/dev/null; then
        red "未检测到 NodePass (np 命令不存在)"
        exit 1
    fi
}

# =========================
# 获取服务状态
# =========================
get_status(){
    if systemctl list-unit-files | grep -q nodepass; then
        STATUS=$(systemctl is-active nodepass 2>/dev/null)
        if [[ "$STATUS" == "active" ]]; then
            green "服务状态: 运行中"
        else
            red "服务状态: 已停止"
        fi
    else
        yellow "服务状态: 未运行"
    fi
}

# =========================
# 主菜单
# =========================
main_menu(){
    clear
    green "========== NodePass 管理菜单 =========="
    echo
    get_status
    echo
    green " 1. 安装 NodePass"
    green " 2. 卸载 NodePass"
    green " 3. 升级 NodePass"
    green " 4. 切换版本 (Stable/Dev/LTS)"
    green " 5. 启动/停止服务"
    green " 6. 修改 API Key"
    green " 7. 查看 API 信息"
    green " 8. 查看帮助"
    green " 0. 退出"
    echo
    read -p "请输入选项: " num

    case "$num" in
        1) np -i ;;
        2) np -u ;;
        3) np -v ;;
        4) np -t ;;
        5) np -o ;;
        6) np -k ;;
        7) np -s ;;
        8) np -h ;;
        0) exit 0 ;;
        *) red "无效选项"; sleep 1 ;;
    esac

    read -p "按回车返回菜单..."
    main_menu
}

check_np
main_menu

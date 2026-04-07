#!/bin/bash
# ========================================
# dstatus 一键管理
# Debian 12 / Ubuntu 兼容
# 基于官方安装脚本
# ========================================

GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
RED="\033[31m"

INSTALL_DIR="/opt/dstatus"
DEFAULT_PORT="5555"
SERVICE_NAME="dstatus"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行此脚本${RESET}"
    exit 1
fi

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    echo "无法获取公网 IP 地址。" && return
}

function menu() {
    clear
    echo -e "${GREEN}=== Dstatus 管理菜单 ===${RESET}"
    echo -e "${GREEN}1) 安装启动${RESET}"
    echo -e "${GREEN}2) 更新${RESET}"
    echo -e "${GREEN}3) 查看服务状态${RESET}"
    echo -e "${GREEN}4) 重启服务${RESET}"
    echo -e "${GREEN}5) 停止服务${RESET}"
    echo -e "${GREEN}6) 卸载(保留数据)${RESET}"
    echo -e "${GREEN}7) 卸载(清空数据)${RESET}"
    echo -e "${GREEN}0) 退出${RESET}"

    read -p "$(echo -e ${GREEN}请选择:${RESET}) " choice

    case $choice in
        1) install_app ;;
        2) update_app ;;
        3) view_status ;;
        4) restart_app ;;
        5) stop_app ;;
        6) uninstall_app ;;
        7) purge_app ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; menu ;;
    esac
}

function check_requirements() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${YELLOW}未检测到 curl，正在安装...${RESET}"
        apt update
        apt install -y curl
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}当前系统不支持 systemd，无法管理 dstatus 服务${RESET}"
        exit 1
    fi
}

function install_app() {
    check_requirements

    echo -e "${GREEN}开始安装 dstatus...${RESET}"
    read -p "请输入监听端口 [默认: ${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    read -p "是否启用 watchtower(自动更新)？[Y/n]: " ENABLE_WATCHTOWER

    WATCHTOWER_ARG="--enable-watchtower"
    if [[ "$ENABLE_WATCHTOWER" == "n" || "$ENABLE_WATCHTOWER" == "N" ]]; then
        WATCHTOWER_ARG=""
    fi

    echo -e "${GREEN}正在执行官方安装脚本...${RESET}"
    curl -fsSL dstatus.sh | bash -s -- --port="$PORT" --install-dir="$INSTALL_DIR" $WATCHTOWER_ARG

    echo
    SERVER_IP=$(get_public_ip)

    echo -e "${GREEN}✅ dstatus 安装完成${RESET}"
    echo -e "${YELLOW}服务名: ${SERVICE_NAME}${RESET}"
    echo -e "${YELLOW}安装目录: ${INSTALL_DIR}${RESET}"
    echo -e "${YELLOW}访问端口: ${PORT}${RESET}"
    echo -e "${YELLOW}访问地址: http://${SERVER_IP}:${PORT}${RESET}"

    if [[ -n "$WATCHTOWER_ARG" ]]; then
        echo -e "${YELLOW}Watchtower: 已启用${RESET}"
    else
        echo -e "${YELLOW}Watchtower: 未启用${RESET}"
    fi

    read -p "按回车返回菜单..."
    menu
}


function update_app() {
    check_requirements

    echo -e "${GREEN}更新 dstatus 到最新版...${RESET}"
    curl -fsSL dstatus.sh | bash -s -- --update

    echo -e "${GREEN}✅ dstatus 已更新${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function view_status() {
    systemctl status "$SERVICE_NAME" --no-pager

    read -p "按回车返回菜单..."
    menu
}

function restart_app() {
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}✅ 服务已重启${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function stop_app() {
    systemctl stop "$SERVICE_NAME"

    echo -e "${GREEN}✅ 服务已停止${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function uninstall_app() {
    check_requirements

    echo -e "${YELLOW}即将卸载 dstatus（保留数据）...${RESET}"
    curl -fsSL dstatus.sh | bash -s -- --uninstall

    echo -e "${GREEN}✅ dstatus 已卸载（数据保留）${RESET}"

    read -p "按回车返回菜单..."
    menu
}

function purge_app() {
    check_requirements

    echo -e "${RED}警告：此操作将完全删除 dstatus 和所有数据！${RESET}"
    read -p "确认继续吗？输入 yes 确认: " CONFIRM

    if [ "$CONFIRM" = "yes" ]; then
        curl -fsSL dstatus.sh | bash -s -- --uninstall --purge-data --yes
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}✅ dstatus 已完全删除${RESET}"
    else
        echo -e "${YELLOW}已取消操作${RESET}"
    fi

    read -p "按回车返回菜单..."
    menu
}

menu

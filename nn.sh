#!/usr/bin/env bash

set -e

SERVICE_NAME=""
PKG_MANAGER=""
PKG_REMOVE_CMD=""
PKG_INSTALL_CMD=""

detect_service() {
    if systemctl list-unit-files | grep -q '^vnstat\.service'; then
        SERVICE_NAME="vnstat"
    elif systemctl list-unit-files | grep -q '^vnstatd\.service'; then
        SERVICE_NAME="vnstatd"
    else
        SERVICE_NAME="vnstat"
    fi
}

detect_package_manager() {
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_INSTALL_CMD="apt update && apt install -y vnstat"
        PKG_REMOVE_CMD="apt remove -y vnstat && apt autoremove -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_INSTALL_CMD="dnf install -y epel-release || true; dnf install -y vnstat"
        PKG_REMOVE_CMD="dnf remove -y vnstat"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_INSTALL_CMD="yum install -y epel-release || true; yum install -y vnstat"
        PKG_REMOVE_CMD="yum remove -y vnstat"
    else
        echo "未检测到支持的包管理器（apt/dnf/yum）"
        exit 1
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 身份运行此脚本"
        echo "例如: sudo bash $0"
        exit 1
    fi
}

pause() {
    read -rp "按回车继续..." _
}

install_vnstat() {
    detect_package_manager
    echo "正在安装 vnstat..."
    bash -c "$PKG_INSTALL_CMD"
    detect_service
    systemctl enable "$SERVICE_NAME" --now
    echo "安装完成，服务已启动：$SERVICE_NAME"
}

start_service() {
    detect_service
    systemctl enable "$SERVICE_NAME" --now
    echo "服务已启动并设置为开机自启：$SERVICE_NAME"
}

restart_service() {
    detect_service
    systemctl restart "$SERVICE_NAME"
    echo "服务已重启：$SERVICE_NAME"
}

show_service_status() {
    detect_service
    systemctl status "$SERVICE_NAME" --no-pager
}

list_interfaces() {
    echo "当前网络接口："
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
}

add_interface() {
    list_interfaces
    read -rp "请输入要监控的网卡名: " iface
    if [ -z "$iface" ]; then
        echo "网卡名不能为空"
        return
    fi

    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "网卡不存在: $iface"
        return
    fi

    vnstat -i "$iface" --add || true
    detect_service
    systemctl restart "$SERVICE_NAME"
    echo "已添加监控接口: $iface"
    echo "首次采集需要等待几分钟"
}

show_default_stats() {
    vnstat
}

show_interface_stats() {
    list_interfaces
    read -rp "请输入要查看的网卡名: " iface
    if [ -z "$iface" ]; then
        echo "网卡名不能为空"
        return
    fi
    vnstat -i "$iface"
}

show_daily_stats() {
    read -rp "请输入网卡名（留空则使用默认）: " iface
    if [ -n "$iface" ]; then
        vnstat -i "$iface" -d
    else
        vnstat -d
    fi
}

show_monthly_stats() {
    read -rp "请输入网卡名（留空则使用默认）: " iface
    if [ -n "$iface" ]; then
        vnstat -i "$iface" -m
    else
        vnstat -m
    fi
}

live_monitor() {
    read -rp "请输入网卡名（留空则使用默认）: " iface
    if [ -n "$iface" ]; then
        vnstat -i "$iface" -l
    else
        vnstat -l
    fi
}

remove_vnstat() {
    detect_package_manager
    detect_service

    echo "即将卸载 vnstat"
    read -rp "是否同时删除统计数据库 /var/lib/vnstat ? [y/N]: " remove_db

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

    bash -c "$PKG_REMOVE_CMD"

    if [[ "$remove_db" =~ ^[Yy]$ ]]; then
        rm -rf /var/lib/vnstat
        echo "已删除数据库目录: /var/lib/vnstat"
    fi

    if [ -f /etc/vnstat.conf ]; then
        read -rp "是否删除配置文件 /etc/vnstat.conf ? [y/N]: " remove_conf
        if [[ "$remove_conf" =~ ^[Yy]$ ]]; then
            rm -f /etc/vnstat.conf
            echo "已删除配置文件: /etc/vnstat.conf"
        fi
    fi

    echo "vnstat 已卸载完成"
}

show_menu() {
    clear
    echo "=============================="
    echo "       vnStat 管理脚本"
    echo "=============================="
    echo " 1. 安装 vnstat"
    echo " 2. 启动并设置开机自启"
    echo " 3. 重启服务"
    echo " 4. 查看服务状态"
    echo " 5. 查看网络接口"
    echo " 6. 添加监控接口"
    echo " 7. 查看默认流量统计"
    echo " 8. 查看指定网卡流量"
    echo " 9. 查看日流量统计"
    echo "10. 查看月流量统计"
    echo "11. 实时流量监控"
    echo "12. 卸载 vnstat"
    echo " 0. 退出"
    echo "=============================="
}

main() {
    require_root

    while true; do
        show_menu
        read -rp "请输入选项: " choice
        case "$choice" in
            1)
                install_vnstat
                pause
                ;;
            2)
                start_service
                pause
                ;;
            3)
                restart_service
                pause
                ;;
            4)
                show_service_status
                pause
                ;;
            5)
                list_interfaces
                pause
                ;;
            6)
                add_interface
                pause
                ;;
            7)
                show_default_stats
                pause
                ;;
            8)
                show_interface_stats
                pause
                ;;
            9)
                show_daily_stats
                pause
                ;;
            10)
                show_monthly_stats
                pause
                ;;
            11)
                live_monitor
                ;;
            12)
                remove_vnstat
                pause
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效选项"
                pause
                ;;
        esac
    done
}

main

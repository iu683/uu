#!/bin/bash

# 基础路径设定
CFT_INSTALL_DIR="/opt/cloudflared"
CFT_BIN="/usr/local/bin/cloudflared"
TOKEN_FILE="$CFT_INSTALL_DIR/.token"
IS_OPENWRT=0
IS_ALPINE=0

G_STATUS=""
G_VERSION=""

# GitHub 轮询节点列表
GITHUB_PROXY=(
    'https://gh-proxy.com/'
    'https://v6.gh-proxy.org/'
    'https://ghproxy.lvedong.eu.org/'
    'https://proxy.vvvv.ee/'
    'https://hub.glowp.xyz/'
    '' 
)
DEFAULT_BACKUP_VER="2026.5.0"

# 标准颜色
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

# 检查运行环境与架构
check_env() {
    if [ -f /etc/openwrt_release ]; then
        IS_OPENWRT=1
    elif [ -f /etc/alpine-release ]; then
        IS_ALPINE=1
    fi
}
check_env

get_arch() {
    # Cloudflare 官方发布包命名中，linux-amd64 已经默认兼容了 Alpine musl 环境
    # 因此不需要在文件名末尾拼接 "-musl" 字符串
    case "$(uname -m)" in
        x86_64) echo "amd64";;
        aarch64) echo "arm64";;
        armv7*|armv6*) echo "arm";;
        *) echo "amd64";;
    esac
}

# 自动获取 GitHub 最新版本号
get_auto_version() {
    local fetched_ver=""
    echo -e "${YELLOW}正在尝试获取 GitHub 远端最新 cloudflared 版本号...${RESET}" >&2
    for proxy in "${GITHUB_PROXY[@]}"; do
        fetched_ver=$(curl -sL -m 4 "${proxy}https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *//;s/"//g')
        if [ -n "$fetched_ver" ]; then
            echo "$fetched_ver"
            return 0
        fi
    done
    echo "$DEFAULT_BACKUP_VER"
}

# 下载组件核心逻辑
download_package_loop() {
    local version=$1
    local arch=$2
    local remote_filename="cloudflared-linux-${arch}"
    local success=0

    echo -e "${YELLOW}开始下载 cloudflared 二进制文件 ${version} (${arch})...${RESET}"
    for proxy in "${GITHUB_PROXY[@]}"; do
        local url="${proxy}https://github.com/cloudflare/cloudflared/releases/download/${version}/${remote_filename}"
        if wget -T 10 -O "cloudflared_tmp" "$url"; then
            echo -e "${GREEN}[成功] 下载完成！${RESET}"
            success=1
            break
        else
            rm -f "cloudflared_tmp"
        fi
    done
    [ $success -eq 1 ] && return 0 || return 1
}

# 安装/更新主程序功能
install_or_update_bin() {
    local CFT_VER=$(get_auto_version)
    local ARCH=$(get_arch)
    
    mkdir -p "$CFT_INSTALL_DIR"
    cd "$CFT_INSTALL_DIR" || exit 1

    if download_package_loop "$CFT_VER" "$ARCH"; then
        stop_service 2>/dev/null || true
        mv -f "cloudflared_tmp" "$CFT_BIN"
        chmod +x "$CFT_BIN"
        echo -e "${GREEN}[成功] cloudflared 主程序已就位/更新成功！${RESET}"
        [ -f "$TOKEN_FILE" ] && restart_service
    else
        echo -e "${RED}[严重错误] 下载失败，请检查网络或重试！${RESET}"
    fi
    read -p "按回车返回菜单..." </dev/tty
}

# 更新隧道运行状态
update_status_variables() {
    G_VERSION="未检测到组件"
    G_STATUS="${RED}已停止${RESET}"

    if [ -f "$CFT_BIN" ]; then
        G_VERSION=$($CFT_BIN --version 2>/dev/null | awk '{print $3}' || echo "未知")
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[c]loudflared") && G_STATUS="${GREEN}已启动${RESET}"
        elif [ "$IS_ALPINE" = "1" ]; then
            (rc-service cloudflared status 2>/dev/null | grep -q "started") && G_STATUS="${GREEN}已启动${RESET}"
        else
            (systemctl is-active --quiet cloudflared 2>/dev/null) && G_STATUS="${GREEN}已启动${RESET}"
        fi
    fi
}

# 写入 OpenWrt 守护服务
write_initd_service() {
    local token=$(cat "$TOKEN_FILE" 2>/dev/null)
    [ -z "$token" ] && return 1
    
    cat > /etc/init.d/cloudflared <<EOF
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=$CFT_BIN
start_service() {
    procd_open_instance
    procd_set_param command \$PROG tunnel run --token "$token"
    procd_set_param respawn
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/cloudflared
    /etc/init.d/cloudflared enable
}

# 写入 Alpine (OpenRC) 守护服务
write_openrc_service() {
    local token=$(cat "$TOKEN_FILE" 2>/dev/null)
    [ -z "$token" ] && return 1

    cat > /etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel (Token Mode)"
supervisor="supervise-daemon"
command="$CFT_BIN"
command_args="tunnel run --token $token"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/cloudflared
    rc-update add cloudflared default >/dev/null 2>&1
}

# 写入标准 Linux Systemd 守护服务
write_systemd_service() {
    local token=$(cat "$TOKEN_FILE" 2>/dev/null)
    [ -z "$token" ] && return 1

    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel (Token Mode)
After=network.target

[Service]
Type=simple
ExecStart=$CFT_BIN tunnel run --token $token
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 统合写入守护服务路由
deploy_service_config() {
    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_service
    elif [ "$IS_ALPINE" = "1" ]; then
        write_openrc_service
    else
        write_systemd_service
    fi
}

# 绑定 Token
bind_token() {
    if [ ! -f "$CFT_BIN" ]; then
        echo -e "${RED}错误：本地没有主程序，请先执行选项 1 安装主程序！${RESET}"
        sleep 2
        return
    fi

    echo "=== 绑定 Cloudflare Tunnel Token ==="
    echo -e "${YELLOW}请输入你在 Cloudflare 网页端获取的官方一键 Token (eyJhIjoi...):${RESET}"
    read -p "Token: " input_token </dev/tty
    
    if [ -z "$input_token" ]; then
        echo -e "${RED}Token 不能为空，放弃操作。${RESET}"
        sleep 1.5
        return
    fi

    mkdir -p "$CFT_INSTALL_DIR"
    rm -f "$CFT_INSTALL_DIR/config.yml" "$CFT_INSTALL_DIR/tunnel_cred.json" "$CFT_INSTALL_DIR/.cft_inited"
    
    echo "$input_token" | tr -d '\r\n ' > "$TOKEN_FILE"
    echo -e "${GREEN}Token 记录成功！正在配置并尝试拉起服务...${RESET}"
    
    deploy_service_config
    start_service
    sleep 1.5
}

# 启动服务
start_service() {
    if [ ! -f "$CFT_BIN" ] || [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${RED}错误：未安装主程序或未绑定 Token！${RESET}"; sleep 2; return
    fi

    deploy_service_config
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/cloudflared start
    elif [ "$IS_ALPINE" = "1" ]; then
        rc-service cloudflared start
    else
        systemctl start cloudflared
        systemctl enable cloudflared 2>/dev/null || true
    fi
    echo "隧道服务已启动"; sleep 1;
}

# 停止服务
stop_service() {
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/cloudflared stop
    elif [ "$IS_ALPINE" = "1" ]; then
        rc-service cloudflared stop 2>/dev/null || true
    else
        systemctl stop cloudflared
    fi
    echo "隧道服务已停止"; sleep 1;
}

# 重启服务
restart_service() {
    if [ ! -f "$CFT_BIN" ] || [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${RED}错误：未安装主程序或未绑定 Token！${RESET}"; sleep 2; return
    fi

    deploy_service_config
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/cloudflared restart
    elif [ "$IS_ALPINE" = "1" ]; then
        rc-service cloudflared restart
    else
        systemctl restart cloudflared
    fi
    echo "隧道服务已重启"; sleep 1;
}

# 查看运行日志
log_service() {
    echo -e "${CYAN}=== 正在获取最近的 30 行隧道运行日志 ===${RESET}"
    if [ "$IS_OPENWRT" = "1" ]; then 
        logread | grep cloudflared | tail -n 30 || echo "暂无日志"
    elif [ "$IS_ALPINE" = "1" ]; then
        if [ -f /var/log/messages ]; then
            tail -n 100 /var/log/messages | grep cloudflared | tail -n 30
        else
            echo -e "${YELLOW}Alpine 默认输出至 syslog，请确保已安装 busybox-initscripts 或 syslog-ng${RESET}"
            rc-service cloudflared status
        fi
    else 
        journalctl -u cloudflared -n 30 --no-pager 2>/dev/null || tail -n 30 /var/log/messages 2>/dev/null
    fi
    read -p "按回车返回菜单..." </dev/tty
}

# 彻底卸载
uninstall_service() {
    echo -e "${RED}确定要彻底卸载本地服务及清除所有配置吗？(y/n)${RESET}"
    read -p "请输入: " confirm </dev/tty
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        stop_service 2>/dev/null || true
        if [ "$IS_OPENWRT" = "1" ]; then
            /etc/init.d/cloudflared disable 2>/dev/null || true
            rm -f /etc/init.d/cloudflared
        elif [ "$IS_ALPINE" = "1" ]; then
            rc-update del cloudflared default >/dev/null 2>&1 || true
            rm -f /etc/init.d/cloudflared
        else
            systemctl disable cloudflared 2>/dev/null || true
            rm -f /etc/systemd/system/cloudflared.service
            systemctl daemon-reload
        fi
        rm -rf "$CFT_INSTALL_DIR" "$CFT_BIN"
        echo -e "${GREEN}Cloudflare Tunnel 已完全卸载干净。${RESET}"
        sleep 2
    fi
}

# ---------- 主菜单界面 ----------
main_menu() {
    while true; do
        update_status_variables
        clear
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN}   Cloudflare 远端控制管理面板    ${RESET}"
        echo -e "${CYAN}   (Dashboard 模式/无需本地配置)  ${RESET}"
        echo -e "${CYAN}================================${RESET}"
        [ ! -f "$CFT_BIN" ] && echo -e "${RED}[警告] 未找到执行文件，请先执行选项 1 安装！${RESET}"
        echo -e "${CYAN}当前状态 :${RESET} $G_STATUS"
        echo -e "${CYAN}主程序版 :${RESET} ${YELLOW}${G_VERSION}${RESET}"
        echo -e "${CYAN}管理提示 : 规则增删请直接在网页面板操作${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN} 1. 安装 / 更新本地 cloudflared 主程序${RESET}"
        echo -e "${CYAN} 2. 绑定 / 修改云端 Token${RESET}"
        echo -e "${CYAN} 3. 启动隧道服务${RESET}"
        echo -e "${CYAN} 4. 停止隧道服务${RESET}"
        echo -e "${CYAN} 5. 重启隧道服务${RESET}"
        echo -e "${CYAN} 6. 查看本地运行日志${RESET}"
        echo -e "${CYAN} 7. 彻底卸载服务与清除残留${RESET}"
        echo -e "${CYAN} 0. 退出${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -ne "${CYAN}请输入选项: ${RESET}"
        read choice </dev/tty
        case $choice in
            1) install_or_update_bin ;;
            2) bind_token ;;
            3) start_service ;;
            4) stop_service ;;
            5) restart_service ;;
            6) log_service ;;
            7) uninstall_service ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" && sleep 1 ;;
        esac
    done
}

main_menu

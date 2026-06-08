#!/bin/bash

# 基础路径设定
CFT_BIN="/usr/local/bin/cloudflared"
TOKEN_FILE="/opt/cloudflared/.token"
IS_OPENWRT=0

G_STATUS=""
G_VERSION=""

# 标准颜色
CYAN="\e[36m"
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

# 检查运行环境
is_openwrt() { [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0; }
is_openwrt

# 更新隧道运行状态
update_status_variables() {
    G_VERSION="未检测到组件"
    G_STATUS="${RED}已停止${RESET}"

    if [ -f "$CFT_BIN" ]; then
        G_VERSION=$($CFT_BIN --version 2>/dev/null | awk '{print $3}' || echo "未知")
        
        if [ "$IS_OPENWRT" = "1" ]; then
            (ps | grep -v grep | grep -q "[c]loudflared") && G_STATUS="${GREEN}已启动${RESET}"
        else
            (systemctl is-active --quiet cloudflared 2>/dev/null) && G_STATUS="${GREEN}已启动${RESET}"
        fi
    else
        echo -e "${RED}[警告] 在 $CFT_BIN 未找到 cloudflared 执行文件，请先安装！${RESET}" >&2
    fi
}

# 写入 OpenWrt 守护服务
write_initd_service() {
    local token=$(cat "$TOKEN_FILE" 2>/dev/null)
    cat > /etc/init.d/cloudflared <<EOF
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=$CFT_BIN
start_service() {
    procd_open_instance
    procd_set_param command \$PROG tunnel run --token $token
    procd_set_param respawn
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/cloudflared
    /etc/init.d/cloudflared enable
}

# 写入标准 Linux Systemd 守护服务
write_systemd_service() {
    local token=$(cat "$TOKEN_FILE" 2>/dev/null)
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

# 绑定 Token
bind_token() {
    echo "=== 绑定 Cloudflare Tunnel Token ==="
    echo -e "${YELLOW}请输入你在 Cloudflare 网页端获取的官方一键 Token (eyJhIjoi...):${RESET}"
    read -p "Token: " input_token </dev/tty
    
    if [ -z "$input_token" ]; then
        echo -e "${RED}Token 不能为空，放弃操作。${RESET}"
        sleep 1.5
        return
    fi

    mkdir -p "$(dirname "$TOKEN_FILE")"
    echo "$input_token" > "$TOKEN_FILE"
    echo -e "${GREEN}Token 绑定成功！正在尝试启动服务...${RESET}"
    
    start_service
}

# 启动服务
start_service() {
    if [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${RED}错误：请先选择选项 1 绑定你的 Token！${RESET}"
        sleep 2
        return
    fi

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_service
        /etc/init.d/cloudflared start
    else
        write_systemd_service
        systemctl start cloudflared
        systemctl enable cloudflared 2>/dev/null || true
    fi
    echo "隧道服务已启动"; sleep 1;
}

# 停止服务
stop_service() {
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/cloudflared stop
    else
        systemctl stop cloudflared
    fi
    echo "隧道服务已停止"; sleep 1;
}

# 重启服务
restart_service() {
    if [ ! -f "$TOKEN_FILE" ]; then
        echo -e "${RED}错误：未绑定 Token！${RESET}"
        sleep 2
        return
    fi

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_service
        /etc/init.d/cloudflared restart
    else
        write_systemd_service
        systemctl restart cloudflared
    fi
    echo "隧道服务已重启"; sleep 1;
}

# 查看运行日志
log_service() {
    echo -e "${CYAN}=== 正在获取最近的 30 行隧道运行日志 ===${RESET}"
    if [ "$IS_OPENWRT" = "1" ]; then 
        logread | grep cloudflared | tail -n 30 || echo "暂无日志"
    else 
        journalctl -u cloudflared -n 30 --no-pager || tail -n 30 /var/log/messages 2>/dev/null
    fi
    read -p "按回车返回菜单..." </dev/tty
}

# 卸载本地守护服务
uninstall_service() {
    echo -e "${RED}确定要卸载本地的 cloudflared 守护服务吗？(y/n)${RESET}"
    read -p "请输入: " confirm </dev/tty
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        stop_service
        if [ "$IS_OPENWRT" = "1" ]; then
            rm -f /etc/init.d/cloudflared
        else
            systemctl disable cloudflared 2>/dev/null
            rm -f /etc/systemd/system/cloudflared.service
            systemctl daemon-reload
        fi
        rm -rf "/opt/cloudflared"
        echo -e "${GREEN}本地守护服务及 Token 已清除（未删除二进制主程序）。${RESET}"
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
        echo -e "${CYAN}当前状态 :${RESET} $G_STATUS"
        echo -e "${CYAN}主程序版 :${RESET} ${YELLOW}${G_VERSION}${RESET}"
        echo -e "${CYAN}管理提示 : 规则增删请直接在网页面板操作${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -e "${CYAN} 1. 绑定 / 修改云端 Token${RESET}"
        echo -e "${CYAN} 2. 启动隧道服务${RESET}"
        echo -e "${CYAN} 3. 停止隧道服务${RESET}"
        echo -e "${CYAN} 4. 重启隧道服务${RESET}"
        echo -e "${CYAN} 5. 查看本地运行日志${RESET}"
        echo -e "${CYAN} 6. 卸载本地守护服务${RESET}"
        echo -e "${CYAN} 0. 退出${RESET}"
        echo -e "${CYAN}================================${RESET}"
        echo -ne "${CYAN}请输入选项: ${RESET}"
        read choice </dev/tty
        case $choice in
            1) bind_token ;;
            2) start_service ;;
            3) stop_service ;;
            4) restart_service ;;
            5) log_service ;;
            6) uninstall_service ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项！${RESET}" && sleep 1 ;;
        esac
    done
}

main_menu

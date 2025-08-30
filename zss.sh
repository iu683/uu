#!/bin/bash

# ==========================================
# VPS 项目 IP + 端口访问管理（批量 + 自动备份 + 自动恢复）
# 支持 Nginx + 防火墙，保证证书续期
# ==========================================

GREEN="\033[0;32m"
RED="\033[0;31m"
RESET="\033[0m"

BACKUP_DIR="/root/ip_block_backup"
mkdir -p $BACKUP_DIR

# 检查 root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 root 用户运行脚本${RESET}"
   exit 1
fi

timestamp() {
    date +"%Y%m%d_%H%M%S"
}

backup_nginx() {
    ts=$(timestamp)
    tar -czf $BACKUP_DIR/nginx_conf_backup_$ts.tar.gz /etc/nginx/conf.d/
    echo -e "${GREEN}已备份 Nginx 配置到 $BACKUP_DIR/nginx_conf_backup_$ts.tar.gz${RESET}"
}

backup_iptables() {
    ts=$(timestamp)
    iptables-save > $BACKUP_DIR/iptables_backup_$ts.rules
    echo -e "${GREEN}已备份防火墙规则到 $BACKUP_DIR/iptables_backup_$ts.rules${RESET}"
}

menu() {
    clear
    echo -e "${GREEN}=== VPS IP + 端口访问管理（批量 + 自动备份 + 自动恢复） ===${RESET}"
    echo "1) 批量添加禁止 IP + 端口访问（只允许域名访问）"
    echo "2) 批量解除禁止（移除防火墙规则 + 可选 Nginx 配置）"
    echo "3) 查看防火墙规则"
    echo "4) 自动恢复最新备份（Nginx + 防火墙）"
    echo "0) 退出"
    read -p "请选择操作: " choice
    case $choice in
        1) add_blocks ;;
        2) remove_blocks ;;
        3) view_rules ;;
        4) restore_latest_backup ;;
        0) exit 0 ;;
        *) echo "无效选项"; sleep 1; menu ;;
    esac
}

# -------------------------------
# 批量添加禁止
# -------------------------------
add_blocks() {
    backup_nginx
    backup_iptables

    echo -e "${GREEN}请输入端口和域名，格式: 端口 域名，一行一个，输入空行结束${RESET}"
    declare -a PORTS
    declare -a DOMAINS
    while true; do
        read -p "> " line
        [[ -z "$line" ]] && break
        PORTS+=($(echo $line | awk '{print $1}'))
        DOMAINS+=($(echo $line | awk '{print $2}'))
    done

    for i in "${!PORTS[@]}"; do
        PORT=${PORTS[$i]}
        DOMAIN=${DOMAINS[$i]}
        NGINX_CONF="/etc/nginx/conf.d/block_ip_${PORT}.conf"

        cat > $NGINX_CONF <<EOF
server {
    listen $PORT default_server;
    server_name _;
    return 444;
}

server {
    listen $PORT;
    server_name $DOMAIN www.$DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;

        location /.well-known/acme-challenge/ {
            root /var/www/html;
        }
    }
}
EOF
        echo -e "${GREEN}生成 Nginx 配置: $DOMAIN:$PORT${RESET}"

        # 防火墙规则
        iptables -A INPUT -p tcp -s 127.0.0.1 --dport $PORT -j ACCEPT
        iptables -A INPUT -p tcp --dport $PORT -j DROP
    done

    nginx -t && systemctl reload nginx
    iptables-save > /etc/iptables.rules

    echo -e "${GREEN}批量添加完成${RESET}"
    read -p "按回车返回菜单" ; menu
}

# -------------------------------
# 批量解除禁止
# -------------------------------
remove_blocks() {
    backup_nginx
    backup_iptables

    iptables -L -n --line-numbers
    echo -e "${GREEN}请输入要删除的规则编号，用空格分隔${RESET}"
    read -p "> " nums
    for NUM in $nums; do
        iptables -D INPUT $NUM
    done
    iptables-save > /etc/iptables.rules

    read -p "是否删除对应的 Nginx 配置？[y/N]: " yn
    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        echo -e "${GREEN}请输入要删除的端口列表，用空格分隔${RESET}"
        read -p "> " ports
        for PORT in $ports; do
            CONF="/etc/nginx/conf.d/block_ip_${PORT}.conf"
            [[ -f "$CONF" ]] && rm -f $CONF
        done
        systemctl reload nginx
        echo -e "${GREEN}Nginx 配置已删除${RESET}"
    fi

    read -p "按回车返回菜单" ; menu
}

# -------------------------------
# 查看规则
# -------------------------------
view_rules() {
    iptables -L -n --line-numbers
    read -p "按回车返回菜单" ; menu
}

# -------------------------------
# 自动恢复最新备份
# -------------------------------
restore_latest_backup() {
    # 找到最新 Nginx 备份
    latest_nginx=$(ls -1t $BACKUP_DIR/nginx_conf_backup_*.tar.gz 2>/dev/null | head -n1)
    latest_iptables=$(ls -1t $BACKUP_DIR/iptables_backup_*.rules 2>/dev/null | head -n1)

    if [[ -z "$latest_nginx" || -z "$latest_iptables" ]]; then
        echo -e "${RED}没有找到备份文件${RESET}"
        read -p "按回车返回菜单" ; menu
        return
    fi

    echo -e "${GREEN}恢复最新备份:${RESET}"
    echo "Nginx: $latest_nginx"
    echo "防火墙: $latest_iptables"

    # 恢复 Nginx
    tar -xzf $latest_nginx -C /
    systemctl reload nginx
    echo -e "${GREEN}Nginx 配置已恢复${RESET}"

    # 恢复防火墙
    iptables-restore < $latest_iptables
    iptables-save > /etc/iptables.rules
    echo -e "${GREEN}防火墙规则已恢复${RESET}"

    read -p "按回车返回菜单" ; menu
}

menu

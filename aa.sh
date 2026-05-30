#!/usr/bin/env bash
#
# V2Ray Socks5 核心 Alpine 专属管理面板 
# SPDX-License-Identifier: MIT
#

set -e
export LANG=en_US.UTF-8

# =========================================================
# 1. 配置文件和日志路径
# =========================================================
WORKDIR="/etc/v2ray"
CONFIG_FILE="/etc/v2ray/config.json"
V2RAY_LOG="/var/log/v2ray/access.log"
CREDENTIALS_FILE="/etc/v2ray/credentials.txt"

# 颜色定义
GREEN="\033[0;32m"
BLUE="\033[0;34m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[1;37m"
NC="\033[0m"

# =========================================================
# 2. 基础辅助与探测工具函数
# =========================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误: 请使用root权限运行此脚本!${NC}"
        exit 1
    fi
}

pause() { 
    read -r -n 1 -s -r -p "按任意键返回菜单..." || true
    echo 
}

# 生成随机端口(1024-65535)
generate_random_port() {
    echo $(( (RANDOM % 64511) + 1024 ))
}

# 生成随机用户名和密码
generate_random_credentials() {
    local username=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)
    local password=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)
    echo "$username:$password"
}

get_public_ip() {
    local ip
    for svc in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
        ip=$(curl -s --max-time 5 "$svc" || wget -T 5 -qO- "$svc" || true)
        ip=$(echo "$ip" | tr -d '[:space:]')
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "127.0.0.1"
}

# 从 config.json 精准动态反查当前配置
load_current_config() {
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        CURRENT_PORT=$(jq -r '.inbounds[0].port' "$CONFIG_FILE" 2>/dev/null || echo "")
        CURRENT_USER=$(jq -r '.inbounds[0].settings.accounts[0].user' "$CONFIG_FILE" 2>/dev/null || echo "")
        CURRENT_PASS=$(jq -r '.inbounds[0].settings.accounts[0].pass' "$CONFIG_FILE" 2>/dev/null || echo "")
    else
        CURRENT_PORT=""
        CURRENT_USER=""
        CURRENT_PASS=""
    fi
}

# 检查本地端口监听状态
check_port_listening() {
    local port=$1
    if [[ -n "$port" ]]; then
        netstat -an 2>/dev/null | grep -E "[:\.]${port} " | grep -i "listen"
    fi
}

# =========================================================
# 3. 安装与依赖部署模块
# =========================================================
install_dependencies() {
    echo -e "${BLUE}正在检查并安装依赖项...${NC}"
    
    # 更新软件包索引
    if ! apk update; then
        echo -e "${RED}更新软件包索引失败，将尝试直接安装...${NC}"
    fi
    
    # 安装基本工具
    echo -e "${BLUE}安装基础工具...${NC}"
    if ! apk add --no-cache curl jq openrc; then
        echo -e "${RED}安装基础工具失败${NC}"
        return 1
    fi
    
    # 安装V2Ray
    echo -e "${BLUE}安装V2Ray...${NC}"
    if ! apk add --no-cache v2ray; then
        echo -e "${RED}安装V2Ray失败。可能是由于内存不足或网络问题。${NC}"
        return 1
    fi
    
    # 创建必要的目录
    mkdir -p /etc/v2ray
    mkdir -p /var/log/v2ray
    
    # 检查V2Ray服务是否存在，不存在则手动创建
    if ! ls /etc/init.d/v2ray >/dev/null 2>&1; then
        echo -e "${RED}找不到V2Ray服务。尝试手动创建服务文件...${NC}"
        
        cat > /etc/init.d/v2ray << 'EOF'
#!/sbin/openrc-run

name="V2Ray"
description="V2Ray Service"
command="/usr/bin/v2ray"
command_args="run -config /etc/v2ray/config.json"
pidfile="/var/run/v2ray.pid"
command_background="yes"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 -o root:root /var/log/v2ray
}
EOF
        chmod +x /etc/init.d/v2ray
    fi
    
    # 启用V2Ray服务
    if ! rc-update add v2ray default; then
        echo -e "${RED}无法启用V2Ray服务开机自启。继续但某些功能可能无法工作。${NC}"
    fi
    
    echo -e "${GREEN}依赖安装完成${NC}"
    return 0
}

# 验证V2Ray是否正确安装
verify_v2ray() {
    if ! command -v v2ray >/dev/null 2>&1; then
        echo -e "${RED}V2Ray未安装或不在PATH中。${NC}"
        return 1
    fi
    if ! [ -f /etc/init.d/v2ray ]; then
        echo -e "${RED}找不到V2Ray服务文件。${NC}"
        return 1
    fi
    return 0
}

# =========================================================
# 4. 配置写入与凭据存储模块
# =========================================================
save_credentials() {
    local port=$1
    local username=$2
    local password=$3
    
    echo "端口: $port" > "$CREDENTIALS_FILE"
    echo "用户名: $username" >> "$CREDENTIALS_FILE"
    echo "密码: $password" >> "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    echo -e "${GREEN}凭据已保存到 $CREDENTIALS_FILE${NC}"
}

configure_v2ray() {
    local port=$1
    local username=$2
    local password=$3
    
    mkdir -p /etc/v2ray
    
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": $port,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$username",
            "pass": "$password"
          }
        ],
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

    echo -e "${GREEN}V2Ray已配置为使用端口 $port 和用户名/密码认证${NC}"
    save_credentials "$port" "$username" "$password"
}

# =========================================================
# 5. 主流程交互模块（安装、修改、启动、停止、查看）
# =========================================================
core_install_or_modify() {
    install_dependencies
    if ! verify_v2ray; then
        echo -e "${RED}环境验证未通过，停止配置。${NC}"
        return 1
    fi

    load_current_config
    echo -e "${PURPLE}====== 配置 V2Ray Socks5 参数 ======${NC}"
    
    # 1. 端口配置与占用拦截
    local final_port=""
    local default_p
    default_p=${CURRENT_PORT:-$(generate_random_port)}
    while true; do
        read -r -p "👉 请输入监听端口 (回车默认: ${default_p}): " input_port
        final_port=${input_port:-$default_p}
        if ! [[ "${final_port}" =~ ^[0-9]+$ ]] || [ "${final_port}" -lt 1 ] || [ "${final_port}" -gt 65535 ]; then
            echo -e "${RED}端口输入无效，请输入 1-65535 之间的数字。${NC}"
            continue
        fi
        if [[ "$final_port" != "$CURRENT_PORT" && -n $(check_port_listening "$final_port") ]]; then
            echo -e "${RED}${final_port} 端口已被其他程序占用，请更换端口。${NC}"
            default_p=$(generate_random_port)
            continue
        fi
        break
    done

    # 2. 账号密码配置
    local raw_creds=$(generate_random_credentials)
    local default_user=${CURRENT_USER:-$(echo "$raw_creds" | cut -d':' -f1)}
    local default_pass=${CURRENT_PASS:-$(echo "$raw_creds" | cut -d':' -f2)}

    read -r -p "👉 请设置用户名 (回车默认: ${default_user}): " final_user
    final_user=${final_user:-$default_user}

    read -r -p "👉 请设置密码 (回车默认: ${default_pass}): " final_pass
    final_pass=${final_pass:-$default_pass}

    # 执行配置写入与重启
    configure_v2ray "$final_port" "$final_user" "$final_pass"
    
    echo -e "${BLUE}正在重载 OpenRC 服务状态...${NC}"
    rc-service v2ray restart >/dev/null 2>&1 || ./etc/init.d/v2ray restart >/dev/null 2>&1 || true
    sleep 1.5
    
    show_config_links
}

show_config_links() {
    load_current_config
    if [ -z "$CURRENT_PORT" ]; then
        echo -e "${RED}未检测到有效的 V2Ray 配置文件，请先执行选项 1 安装。${NC}"
        return 1
    fi
    local ip=$(get_public_ip)
    
    echo -e "${GREEN}====== V2Ray Socks5 连接凭证 ======${NC}"
    echo -e "${YELLOW}● 节点地址:${NC} ${ip}"
    echo -e "${YELLOW}● 监听端口:${NC} ${CURRENT_PORT}"
    echo -e "${YELLOW}● 用户名字:${NC} ${CURRENT_USER}"
    echo -e "${YELLOW}● 认证密码:${NC} ${CURRENT_PASS}"
    echo -e "${YELLOW}● 客户端直连格式:${NC} socks://${CURRENT_USER}:${CURRENT_PASS}@${ip}:${CURRENT_PORT}"
    echo
}

uninstall_v2ray() {
    echo -e "${YELLOW}正在从 Alpine 系统卸载 V2Ray 及其所有关联配置...${NC}"
    rc-service v2ray stop >/dev/null 2>&1 || true
    rc-update del v2ray default >/dev/null 2>&1 || true
    rm -f /etc/init.d/v2ray
    apk del v2ray
    rm -rf "$WORKDIR"
    rm -rf /var/log/v2ray
    echo -e "${GREEN}V2Ray 已经彻底从系统中移除！${NC}"
}

# =========================================================
# 6. 面板主菜单循环
# =========================================================
menu() {
    check_root
    
    while true; do
        clear
        load_current_config
        
        # OpenRC 运行状态判定
        local status_display="${RED}● 已停止${NC}"
        if verify_v2ray &>/dev/null; then
            if rc-service v2ray status 2>/dev/null | grep -qi "started" || [ -n "$(check_port_listening "$CURRENT_PORT")" ]; then
                status_display="${GREEN}● 运行中 (OpenRC)${NC}"
            fi
        else
            status_display="${RED}● 未安装核心${NC}"
        fi

        local port_display="${CURRENT_PORT:- -}"
        
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}    V2Ray Socks5 Alpine 面板     ${NC}"
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}状态   :${NC} ${status_display}"
        echo -e "${GREEN}端口   :${NC} ${YELLOW}${port_display}${NC}"
        echo -e "${GREEN}实现   :${NC} ${CYAN}v2ray-core (Socks5)${NC}"
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}1. 安装 / 修改配置${NC}"
        echo -e "${GREEN}2. 卸载 V2Ray${NC}"
        echo -e "${GREEN}3. 启动 V2Ray${NC}"
        echo -e "${GREEN}4. 停止 V2Ray${NC}"
        echo -e "${GREEN}5. 重启 V2Ray${NC}"
        echo -e "${GREEN}6. 查看运行日志${NC}"
        echo -e "${GREEN}7. 查看当前连接配置${NC}"
        echo -e "${GREEN}0. 退出${NC}"
        echo -e "${GREEN}================================${NC}"

        local choice=""
        read -r -p "$(echo -e "${GREEN}请输入选项: ${NC}")" choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) clear; core_install_or_modify; pause ;;
            2) clear; uninstall_v2ray; pause ;;
            3)
                clear
                if ! verify_v2ray; then echo -e "${RED}请先安装核心！${NC}"; else rc-service v2ray start; echo -e "${GREEN}启动指令已执行。${NC}"; fi
                pause ;;
            4)
                clear
                if ! verify_v2ray; then echo -e "${RED}服务未安装！${NC}"; else rc-service v2ray stop; echo -e "${GREEN}停止指令已执行。${NC}"; fi
                pause ;;
            5)
                clear
                if ! verify_v2ray; then echo -e "${RED}服务未安装！${NC}"; else rc-service v2ray restart; echo -e "${GREEN}重启指令已执行。${NC}"; fi
                pause ;;
            6)
                clear
                if [ -f "$V2RAY_LOG" ]; then
                    echo -e "${PURPLE}=== 最新 50 行访问日志 ===${NC}"
                    tail -n 50 "$V2RAY_LOG"
                else
                    echo -e "${YELLOW}暂无可用访问日志或未产生流量。${NC}"
                fi
                pause ;;
            7) clear; show_config_links; pause ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项，请重新选择！${NC}"; sleep 1 ;;
        esac
    done
}

menu "$@"

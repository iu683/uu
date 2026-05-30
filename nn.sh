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

# 纯 awk URL 编码器（兼容 Alpine 极简环境）
urlencode() {
    local s="$1"
    echo -n "$s" | awk 'BEGIN {
        for (i = 0; i <= 255; i++) ord[sprintf("%c", i)] = i
    }
    {
        encoded = ""
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c ~ /[a-zA-Z0-9_.~-]/) encoded = encoded c
            else encoded = encoded sprintf("%%%02X", ord[c])
        }
        print encoded
    }'
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

# 验证V2Ray是否正确安装
verify_v2ray() {
    if ! command -v v2ray >/dev/null 2>&1; then
        return 1
    fi
    if ! [ -f /etc/init.d/v2ray ]; then
        return 1
    fi
    return 0
}

# 动态获取 V2Ray 版本号
get_v2ray_version() {
    if verify_v2ray; then
        local ver_output
        ver_output=$(v2ray -version 2>/dev/null | head -n 1 | awk '{print $2}')
        echo "v2ray-core ${ver_output:-已安装}"
    else
        echo "v2ray-core (未安装)"
    fi
}

# =========================================================
# 3. 依赖部署模块
# =========================================================
install_dependencies() {
    echo -e "${BLUE}正在检查并安装依赖项...${NC}"
    
    # 更新软件包索引
    if ! apk update; then
        echo -e "${RED}警告: 更新软件包索引失败，将尝试直接拉取组件...${NC}"
    fi
    
    # 安装基本工具
    echo -e "${BLUE}安装基础工具...${NC}"
    if ! apk add --no-cache curl jq openrc; then
        echo -e "${RED}错误: 安装基础工具失败${NC}"
        return 1
    fi
    
    # 安装V2Ray
    echo -e "${BLUE}安装V2Ray...${NC}"
    if ! apk add --no-cache v2ray; then
        echo -e "${RED}错误: 安装V2Ray失败。请检查系统网络或内存。${NC}"
        return 1
    fi
    
    # 创建必要的目录
    mkdir -p /etc/v2ray
    mkdir -p /var/log/v2ray
    
    # 检查V2Ray服务是否存在，不存在则手动创建
    if ! ls /etc/init.d/v2ray >/dev/null 2>&1; then
        echo -e "${YELLOW}找不到标准服务文件，正在手动注入 OpenRC 托管脚本...${NC}"
        
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
    rc-update add v2ray default >/dev/null 2>&1 || true
    echo -e "${GREEN}依赖及核心组件安装完成${NC}"
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
    save_credentials "$port" "$username" "$password"
}

# =========================================================
# 5. 主流程控制模块
# =========================================================

# 流程 1：全新的纯净安装
action_install() {
    if verify_v2ray &>/dev/null; then
        echo -e "${YELLOW}提示: 检测到系统中已安装 V2Ray 核心。如果需要调整参数，请使用选项 2 [修改配置]。${NC}"
        return 0
    fi

    if ! install_dependencies; then
        echo -e "${RED}核心部件部署失败，无法继续。${NC}"
        return 1
    fi

    echo -e "${PURPLE}====== 开始初始化 V2Ray Socks5 配置 ======${NC}"
    
    local final_port default_p
    default_p=$(generate_random_port)
    while true; do
        read -r -p "👉 请输入监听端口 (回车随机: ${default_p}): " input_port
        final_port=${input_port:-$default_p}
        if ! [[ "${final_port}" =~ ^[0-9]+$ ]] || [ "${final_port}" -lt 1 ] || [ "${final_port}" -gt 65535 ]; then
            echo -e "${RED}端口格式不合法，请输入 1-65535 的数字。${NC}"
            continue
        fi
        if [[ -n $(check_port_listening "$final_port") ]]; then
            echo -e "${RED}${final_port} 端口已被系统其他程序占用，请更换端口。${NC}"
            default_p=$(generate_random_port)
            continue
        fi
        break
    done

    local raw_creds default_user default_pass
    raw_creds=$(generate_random_credentials)
    default_user=$(echo "$raw_creds" | cut -d':' -f1)
    default_pass=$(echo "$raw_creds" | cut -d':' -f2)

    read -r -p "👉 请设置用户名 (回车随机: ${default_user}): " final_user
    final_user=${final_user:-$default_user}

    read -r -p "👉 请设置密码 (回车随机: ${default_pass}): " final_pass
    final_pass=${final_pass:-$default_pass}

    configure_v2ray "$final_port" "$final_user" "$final_pass"
    
    echo -e "${BLUE}正在调动 OpenRC 唤醒服务...${NC}"
    rc-service v2ray restart >/dev/null 2>&1 || ./etc/init.d/v2ray restart >/dev/null 2>&1 || true
    sleep 1.5
    
    echo -e "${GREEN}🎉 V2Ray 安装并配置成功！${NC}"
    show_config_links
}

# 流程 2：独立的配置修改
action_modify_config() {
    if ! verify_v2ray &>/dev/null; then
        echo -e "${RED}错误: 系统尚未安装 V2Ray 核心，请先执行选项 1 进行安装！${NC}"
        return 1
    fi

    load_current_config
    echo -e "${PURPLE}====== 修改 V2Ray Socks5 配置 ======${NC}"
    echo -e "${CYAN}提示：直接敲回车将完全保持原有参数不变${NC}"
    echo "--------------------------------------------"

    local final_port input_port
    while true; do
        read -r -p "👉 请输入新的监听端口 [当前: ${CURRENT_PORT:-1080}]: " input_port
        if [ -z "$input_port" ]; then
            final_port=$CURRENT_PORT
            break
        fi
        if [[ "${input_port}" =~ ^[0-9]+$ ]] && [ "${input_port}" -ge 1 ] && [ "${input_port}" -le 65535 ]; then
            if [[ "$input_port" != "$CURRENT_PORT" && -n $(check_port_listening "$input_port") ]]; then
                echo -e "${RED}${input_port} 端口已被其他程序占用，请换用其他端口。${NC}"
                continue
            fi
            final_port="${input_port}"
            break
        else
            echo -e "${RED}输入端口格式不合法，请输入 1-65535 之间的纯数字。${NC}"
        fi
    done

    local input_user final_user
    read -r -p "👉 请设置新的用户名 [当前: ${CURRENT_USER:-未设置}]: " input_user
    final_user=${input_user:-$CURRENT_USER}

    local input_pass final_pass
    read -r -p "👉 请设置新的密码 [当前: ${CURRENT_PASS:-未设置}]: " input_pass
    final_pass=${input_pass:-$CURRENT_PASS}

    configure_v2ray "$final_port" "$final_user" "$final_pass"
    
    echo -e "${BLUE}正在重载服务使新配置生效...${NC}"
    rc-service v2ray restart >/dev/null 2>&1 || ./etc/init.d/v2ray restart >/dev/null 2>&1 || true
    sleep 1.5
    
    echo -e "${GREEN}修改成功！新参数已即时应用。${NC}"
    show_config_links
}

show_config_links() {
    load_current_config
    if [ -z "$CURRENT_PORT" ]; then
        echo -e "${RED}未检测到合法的 V2Ray 节点配置。${NC}"
        return 1
    fi
    local ip=$(get_public_ip)
    
    # 转换各种参数做标准的 URL 安全转义
    local enc_ip enc_port enc_user enc_pass
    enc_ip=$(urlencode "$ip")
    enc_port="$CURRENT_PORT"
    enc_user=$(urlencode "$CURRENT_USER")
    enc_pass=$(urlencode "$CURRENT_PASS")

    local直连格式="socks://${CURRENT_USER}:${CURRENT_PASS}@${ip}:${CURRENT_PORT}"
    local tg快捷链="https://t.me/socks?server=${enc_ip}&port=${enc_port}&user=${enc_user}&pass=${enc_pass}"

    echo -e "${GREEN}====== Socks5 当前配置详情 ======${NC}"
    echo -e "${YELLOW}● 节点 IP :${NC} ${ip}"
    echo -e "${YELLOW}● 端口号  :${NC} ${CURRENT_PORT}"
    echo -e "${YELLOW}● 用户名  :${NC} ${CURRENT_USER}"
    echo -e "${YELLOW}● 认证密码:${NC} ${CURRENT_PASS}"
    echo "--------------------------------------------"
    echo -e "${YELLOW}● 客户端直连格式:${NC}\n  ${直连格式}"
    echo -e "${YELLOW}● Telegram 一键导入链接:${NC}\n  ${tg快捷链}"
    echo
}

uninstall_v2ray() {
    echo -e "${YELLOW}正在从 Alpine 系统卸载 V2Ray 及其所有关联配置...${NC}"
    rc-service v2ray stop >/dev/null 2>&1 || true
    rc-update del v2ray default >/dev/null 2>&1 || true
    rm -f /etc/init.d/v2ray
    apk del v2ray || true
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
        
        # 1. 精准获取当前状态
        local status_display="${RED}● 已停止${NC}"
        if ! verify_v2ray &>/dev/null; then
            status_display="${RED}● 未安装核心${NC}"
        else
            if rc-service v2ray status 2>/dev/null | grep -qi "started" || [ -n "$(check_port_listening "$CURRENT_PORT")" ]; then
                status_display="${GREEN}● 运行中 (OpenRC)${NC}"
            fi
        fi

        # 2. 动态显示端口和实现
        local port_display="${CURRENT_PORT:- -}"
        local engine_display
        engine_display=$(get_v2ray_version)
        
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}    V2Ray Socks5 Alpine 面板     ${NC}"
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}状态   :${NC} ${status_display}"
        echo -e "${GREEN}版本   :${NC} ${CYAN}${engine_display}${NC}"
        echo -e "${GREEN}端口   :${NC} ${YELLOW}${port_display}${NC}"
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}1. 安装 V2Ray${NC}"
        echo -e "${GREEN}2. 修改配置${NC}"
        echo -e "${GREEN}3. 卸载 V2Ray${NC}"
        echo -e "${GREEN}4. 启动 V2Ray${NC}"
        echo -e "${GREEN}5. 停止 V2Ray${NC}"
        echo -e "${GREEN}6. 重启 V2Ray${NC}"
        echo -e "${GREEN}7. 查看运行日志${NC}"
        echo -e "${GREEN}8. 查看连接配置${NC}"
        echo -e "${GREEN}0. 退出${NC}"
        echo -e "${GREEN}================================${NC}"

        local choice=""
        read -r -p "$(echo -e "${GREEN}请输入选项: ${NC}")" choice || true
        [[ -z "$choice" ]] && continue

        case "$choice" in
            1) clear; action_install; pause ;;
            2) clear; action_modify_config; pause ;;
            3)
                clear
                if ! verify_v2ray &>/dev/null; then echo -e "${RED}请先执行选项 1 安装核心！${NC}"; else rc-service v2ray start; echo -e "${GREEN}启动指令已执行。${NC}"; fi
                pause ;;
            4)
                clear
                if ! verify_v2ray &>/dev/null; then echo -e "${RED}服务未安装！${NC}"; else rc-service v2ray stop; echo -e "${GREEN}停止指令已执行。${NC}"; fi
                pause ;;
            5)
                clear
                if ! verify_v2ray &>/dev/null; then echo -e "${RED}服务未安装！${NC}"; else rc-service v2ray restart; echo -e "${GREEN}重启指令已执行。${NC}"; fi
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
            7|8) clear; show_config_links; pause ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项，请重新选择！${NC}"; sleep 1 ;;
        esac
    done
}

menu "$@"

#!/bin/bash

# =========================================================
# Xray Socks5 管理脚本 (Alpine Linux ) 
# =========================================================

set -Eeuo pipefail

# ================== 颜色定义 ==================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# ================== 🚀 服务自定义重命名 ==================
readonly SERV_NAME="xray-socks5"

# ================== 📂 自定义分享链接存放路径 ==================
readonly X_LINK_DIR="/root/proxynode/socks5"

# ================== 路径与日志 (自动联动) ==================
readonly X_DIR="/etc/${SERV_NAME}"
readonly X_CONFIG="${X_DIR}/config.json"
readonly X_BIN="/usr/local/bin/${SERV_NAME}"
readonly X_LINK="${X_LINK_DIR}/${SERV_NAME}_socks5.txt"
readonly X_LOG="/var/log/${SERV_NAME}.log"
readonly INIT_FILE="/etc/init.d/${SERV_NAME}"

# ================== 核心工具 ==================
info() { echo -e "${GREEN}[信息] $*${RESET}"; }
warn() { echo -e "${YELLOW}[警告] $*${RESET}"; }
error() { echo -e "${RED}[错误] $*${RESET}"; }
pause() { echo; echo -ne "${GREEN}按任意键返回菜单...${RESET}"; read -n 1 -s; echo; }

is_valid_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

get_xray_status() {
    if rc-service "$SERV_NAME" status 2>/dev/null | grep -q "started"; then
        echo -e "${GREEN}● 运行中 ${RESET}"
    else 
        echo -e "${RED}● 未运行 ${RESET}"
    fi
}

get_xray_version() {
    if [[ -x "$X_BIN" ]]; then
        "$X_BIN" version 2>/dev/null | head -n 1 | awk '{print $2}'
    else
        echo "未安装"
    fi
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

HOSTNAME=$(hostname -s | sed 's/ /_/g')

# ================== 配置写入 ==================
write_config() {
    local port=$1 user=$2 pass=$3
    mkdir -p "$X_DIR" && chmod 755 "$X_DIR"
    
    # 构造 accounts 数组
    local accounts_json="[]"
    if [[ -n "$user" && -n "$pass" ]]; then
        accounts_json="[{\"user\": \"$user\", \"pass\": \"$pass\"}]"
    fi

    cat > "$X_CONFIG" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port,
        "protocol": "socks",
        "settings": {
            "auth": "$([[ -n "$user" && -n "$pass" ]] && echo "password" || echo "noauth")",
            "accounts": $accounts_json,
            "udp": true
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": { "domainStrategy": "UseIPv4v6" }
    }]
}
EOF
}

# ================== 修改配置 ==================
modify_config() {
    if [[ ! -f "$X_CONFIG" ]]; then error "请先安装 Xray"; return; fi
    
    local curr_port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local curr_user=$(jq -r '.inbounds[0].settings.accounts[0].user // ""' "$X_CONFIG")
    local curr_pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // ""' "$X_CONFIG")

    # 1. 修改端口
    local n_port
    while true; do
        read -p "请输入新 Socks5 端口 (回车保持 $curr_port): " n_port
        n_port=${n_port:-$curr_port}
        is_valid_port "$n_port" && break || error "端口无效，请输入 1-65535 之间的数字。"
    done

    # 2. 修改用户名 (独立分离)
    local n_user
    read -p "请输入新用户名 (回车保持当前, 清空认证输 clear, 输 random 随机生成): " n_user
    n_user=${n_user:-$curr_user}
    
    if [[ "$n_user" == "clear" ]]; then
        n_user=""
    elif [[ "$n_user" == "random" ]]; then
        n_user=$(openssl rand -hex 4)
        info "👉 已生成随机用户名: $n_user"
    fi
    
    # 3. 修改密码 (独立分离)
    local n_pass=""
    if [[ -n "$n_user" ]]; then
        read -p "请输入新密码 (回车保持当前, 输 random 随机生成): " n_pass
        if [[ -z "$n_pass" && -n "$curr_pass" ]]; then
            n_pass="$curr_pass"
        fi

        if [[ "$n_pass" == "random" || -z "$n_pass" ]]; then
            if [[ "$n_pass" == "random" || -z "$curr_pass" ]]; then
                n_pass=$(openssl rand -hex 8)
                info "👉 已生成随机密码: $n_pass"
            fi
        fi

        if [[ -z "$n_pass" ]]; then
            error "错误：启用了用户名认证，密码绝对不能为空！"
            return
        fi
    else
        n_pass=""
        info "👉 认证已清空，变变成免密匿名模式。"
    fi

    write_config "$n_port" "$n_user" "$n_pass"
    rc-service "$SERV_NAME" restart
    
    # 生成新链接
    local ip=$(get_public_ip || echo "127.0.0.1")
    local enc_ip=$(echo -n "$ip" | jq -sRr @uri)
    local enc_user=$(echo -n "$n_user" | jq -sRr @uri)
    local enc_pass=$(echo -n "$n_pass" | jq -sRr @uri)

    mkdir -p "$X_LINK_DIR"
    if [[ -n "$n_user" ]]; then
        echo "socks://${enc_user}:${enc_pass}@${ip}:${n_port}#${HOSTNAME}-socks5" > "$X_LINK"
        echo "https://t.me/socks?server=${enc_ip}&port=${n_port}&user=${enc_user}&pass=${enc_pass}" >> "$X_LINK"
    else
        echo "socks://${ip}:${n_port}#${HOSTNAME}-socks5" > "$X_LINK"
        echo "https://t.me/socks?server=${enc_ip}&port=${n_port}" >> "$X_LINK"
    fi
    info "配置已更新并成功重启服务！"
}

# ================== 安装与管理 (账号密码彻底解耦独立生产) ==================
install_xray() {
    info "正在安装依赖与内核..."
    apk update && apk add curl unzip jq uuidgen gcompat libc6-compat bc openssl > /dev/null 2>&1
    mkdir -p "$X_DIR" && sync
    
    local arch=$(uname -m | sed 's/x86_64/64/;s/aarch64/arm64-v8a/')
    local ver=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    
    info "下载 Xray $ver ($arch)..."
    curl -L -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip"
    unzip -o /tmp/xray.zip -d /tmp/xray_tmp > /dev/null
    mv -f /tmp/xray_tmp/xray "$X_BIN" && chmod +x "$X_BIN"
    rm -rf /tmp/xray*
    
    if [[ ! -f "$X_CONFIG" ]]; then
        local port
        while true; do
            echo -ne "${GREEN}请输入入站端口 (回车随机): ${RESET}"; read port
            [[ -z "$port" ]] && port=$((RANDOM % 45535 + 10000))
            is_valid_port "$port" && break || error "端口无效，请输入 1-65535 之间的数字。"
        done
        
        local user pass
        # 1. 独立询问用户名
        echo -ne "${GREEN}请输入 Socks5 用户名 (直接回车默认随机生成): ${RESET}"; read user
        if [[ -z "$user" ]]; then
            user=$(openssl rand -hex 4)   # 8位随机字符
            info "👉 采用默认随机生成用户名: ${user}"
        fi
        
        # 2. 独立询问密码
        echo -ne "${GREEN}请输入 Socks5 密码 (直接回车默认随机生成): ${RESET}"; read pass
        if [[ -z "$pass" ]]; then
            pass=$(openssl rand -hex 8)   # 16位随机字符
            info "👉 采用默认随机生成密 码: ${pass}"
        else
            while [[ -z "$pass" ]]; do
                echo -ne "${GREEN}密码不能为空，请重新输入 Socks5 密码: ${RESET}"; read pass
            done
        fi
        
        write_config "$port" "$user" "$pass"
        
        # 写入 OpenRC 服务脚本
        cat << EOF > "$INIT_FILE"
#!/sbin/openrc-run
command="${X_BIN}"
command_args="run -c ${X_CONFIG}"
command_background="yes"
pidfile="/run/${SERV_NAME}.pid"
output_log="$X_LOG"
error_log="$X_LOG"
EOF
        chmod +x "$INIT_FILE"
        touch "$X_LOG"
        rc-update add "$SERV_NAME" default >/dev/null 2>&1
    fi

    rc-service "$SERV_NAME" restart
    
    # 读取配置生成双链接
    local ip=$(get_public_ip || echo "127.0.0.1")
    local port=$(jq -r '.inbounds[0].port' "$X_CONFIG")
    local user=$(jq -r '.inbounds[0].settings.accounts[0].user // ""' "$X_CONFIG")
    local pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // ""' "$X_CONFIG")
    
    local enc_ip=$(echo -n "$ip" | jq -sRr @uri)
    local enc_user=$(echo -n "$user" | jq -sRr @uri)
    local enc_pass=$(echo -n "$pass" | jq -sRr @uri)
    
    mkdir -p "$X_LINK_DIR"
    if [[ -n "$user" ]]; then
        echo "socks://${enc_user}:${enc_pass}@${ip}:${port}#${HOSTNAME}-socks5" > "$X_LINK"
        echo "https://t.me/socks?server=${enc_ip}&port=${port}&user=${enc_user}&pass=${enc_pass}" >> "$X_LINK"
    else
        echo "socks://${ip}:${port}#${HOSTNAME}-socks5" > "$X_LINK"
        echo "https://t.me/socks?server=${enc_ip}&port=${port}" >> "$X_LINK"
    fi

    show_current_config
}

# ================== 显示配置 ==================
show_current_config() {
    if [[ ! -f "$X_CONFIG" ]]; then
        error "配置文件不存在"
        return
    fi

    local ip port user pass auth_mode
    ip=$(get_public_ip || echo "未知")
    port=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "未知")
    user=$(jq -r '.inbounds[0].settings.accounts[0].user // "无"' "$X_CONFIG" 2>/dev/null || echo "无")
    pass=$(jq -r '.inbounds[0].settings.accounts[0].pass // "无"' "$X_CONFIG" 2>/dev/null || echo "无")
    
    local auth_status=$(jq -r '.inbounds[0].settings.auth' "$X_CONFIG" 2>/dev/null || echo "noauth")
    [[ "$auth_status" == "password" ]] && auth_mode="用户名密码验证" || auth_mode="匿名免密 (noauth)"

    echo -e "\n${GREEN}====== 当前配置详情 ======${RESET}"
    echo -e "${YELLOW}传输协议     : Socks5 代理${RESET}"
    echo -e "${YELLOW}认证模式     : ${auth_mode}${RESET}"
    echo -e "${YELLOW}IP地址       : ${ip}${RESET}"
    echo -e "${YELLOW}端口         : ${port}${RESET}"
    echo -e "${YELLOW}用户名       : ${user}${RESET}"
    echo -e "${YELLOW}密码         : ${pass}${RESET}"
    echo -e "${YELLOW}分享存放路径 : ${X_LINK}${RESET}"
    
    if [[ -f "$X_LINK" ]]; then
        echo -e "${GREEN}====== 👉 通用客户端 Socks5 链接 ======${RESET}"
        sed -n '1p' "$X_LINK"
        echo -e "${GREEN}====== 🚀 Telegram 内置一键代理链接 ======${RESET}"
        sed -n '2p' "$X_LINK"
    fi
}

# ================== 菜单 ==================
show_menu() {
    clear
    local status=$(get_xray_status)
    local version=$(get_xray_version)
    local port_show="-"
    [[ -f "$X_CONFIG" ]] && port_show=$(jq -r '.inbounds[0].port' "$X_CONFIG" 2>/dev/null || echo "-")

    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}      Xray Socks5 管理面板       ${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN}状态   :${RESET} $status"
    echo -e "${GREEN}版本   :${RESET} ${YELLOW}${version}${RESET}"
    echo -e "${GREEN}端口   :${RESET} ${YELLOW}${port_show}${RESET}"
    echo -e "${GREEN}================================${RESET}"
    echo -e "${GREEN} 1. 安装 Xray Socks5 ${RESET}"
    echo -e "${GREEN} 2. 更新 Xray${RESET}"
    echo -e "${GREEN} 3. 卸载 Xray${RESET}"
    echo -e "${GREEN} 4. 修改配置${RESET}"
    echo -e "${GREEN} 5. 启动 Xray${RESET}"
    echo -e "${GREEN} 6. 停止 Xray${RESET}"
    echo -e "${GREEN} 7. 重启 Xray${RESET}"
    echo -e "${GREEN} 8. 查看日志${RESET}"
    echo -e "${GREEN} 9. 查看节点配置${RESET}"
    echo -e "${GREEN} 0. 退出${RESET}"
    echo -e "${GREEN}================================${RESET}"
}

while true; do
    show_menu
    echo -ne "${GREEN}请输入选项: ${RESET}"; read choice
    case $choice in
        1|2) install_xray; pause ;;
        3) 
            rc-service "$SERV_NAME" stop 2>/dev/null || true
            rc-update del "$SERV_NAME" default 2>/dev/null || true
            rm -rf "$X_DIR" "$X_BIN" "$INIT_FILE" "$X_LINK" "$X_LOG" "$X_LINK_DIR"
            info "卸载完成"
            pause 
            ;;
        4) modify_config; pause ;;
        5) rc-service "$SERV_NAME" start; pause ;;
        6) rc-service "$SERV_NAME" stop; pause ;;
        7) rc-service "$SERV_NAME" restart; pause ;;
        8) [[ -f "$X_LOG" ]] && tail -f "$X_LOG" || error "暂无日志"; pause ;;
        9) show_current_config || error "无配置"; pause ;;
        0) exit 0 ;;
        *) error "无效选项"; sleep 1 ;;
    esac
done
